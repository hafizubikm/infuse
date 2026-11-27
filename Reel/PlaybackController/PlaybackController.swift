import AppKit
import AVFoundation
import Observation

/// UI-facing playback state and commands for one open file (main actor).
@MainActor
@Observable
final class PlaybackController {
    enum Status: Equatable {
        case opening
        case ready
        case playing
        case paused
        case ended
        case failed(String)
    }

    let url: URL
    let videoLayer: AVSampleBufferDisplayLayer
    private(set) var status: Status = .opening
    private(set) var media: PlaybackEngine.OpenedMedia?
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isBuffering = true
    private(set) var warning: String?
    private(set) var speed: Float = 1
    private(set) var volume: Float = 1
    private(set) var isMuted = false
    /// While the user drags the seek bar, the position they are pointing at.
    private(set) var scrubPosition: Double?
    /// What decodes/renders the picture and sound, e.g. "Dolby Vision Profile 8.1 · hardware decode".
    private(set) var videoRenderPath: String?
    private(set) var audioRenderPath: String?
    /// Subtitle tracks (embedded + external files next to the video) and the one shown.
    private(set) var subtitleTracks: [SubtitleTrack] = []
    private(set) var selectedSubtitleID: String?
    /// Short message shown briefly over the video ("Subtitles: English · SRT").
    private(set) var toast: String?
    @ObservationIgnored private(set) var subtitles: SubtitleManager?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// Audio tracks of the file and the one playing.
    private(set) var audioTracks: [StreamInfo] = []
    private(set) var selectedAudioIndex: Int?
    /// Set when playback resumed from a saved position (shows the "Start Over" banner).
    private(set) var resumedFrom: Double?

    /// What was chosen for this file last time.
    struct Preferences {
        var audioStreamIndex: Int?
        var subtitleTrackID: String?
        var subtitlesOff = false
    }

    let identity: FileIdentity
    @ObservationIgnored private let history: PlaybackHistory?
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var lastRecorded: Double = -100
    /// Called whenever transport state changes (play/pause/seek/rate/end) — for Now Playing and PiP.
    @ObservationIgnored var onTransportChange: (() -> Void)?

    /// Called once the file is open (e.g. so the window can size itself to the video).
    var onOpened: ((PlaybackEngine.OpenedMedia) -> Void)?

    @ObservationIgnored private let engine: PlaybackEngine
    @ObservationIgnored private let sleepAssertion = DisplaySleepAssertion()
    @ObservationIgnored private var lastScrubSeek = Date.distantPast
    @ObservationIgnored private var wantsPlay = true
    @ObservationIgnored private var volumeObservers: [NSObjectProtocol] = []

    var isPlaying: Bool { status == .playing }

    /// The playback clock read directly from the synchronizer (for frame-accurate subtitles).
    var preciseTime: Double { scrubPosition ?? engine.currentTime }
    var displayedTime: Double { scrubPosition ?? currentTime }

    init(url: URL, history: PlaybackHistory? = nil, preferences: Preferences = Preferences()) {
        self.url = url
        identity = FileIdentity(url: url)
        self.history = history
        self.preferences = preferences
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        videoLayer = layer
        engine = PlaybackEngine(url: url, videoLayer: layer)
        engine.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        observeVolumeUnmounts()
    }

    func open(startAt: Double = 0, autoplay: Bool = true) {
        wantsPlay = autoplay
        if startAt > 0 { resumedFrom = startAt }
        engine.open(startAt: startAt, autoplay: autoplay, preferredAudioStream: preferences.audioStreamIndex)
    }

    /// "Start Over" after an automatic resume.
    func startOver() {
        resumedFrom = nil
        seek(to: 0)
    }

    func dismissResumeBanner() { resumedFrom = nil }

    // MARK: - Transport

    func play() {
        guard canControl else { return }
        wantsPlay = true
        engine.play()
        status = .playing
        updateSleepAssertion()
        onTransportChange?()
    }

    func pause() {
        guard canControl else { return }
        wantsPlay = false
        engine.pause()
        status = .paused
        updateSleepAssertion()
        recordProgress()
        onTransportChange?()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func seek(to seconds: Double) {
        guard canControl else { return }
        let t = clamp(seconds)
        currentTime = t
        if status == .ended { status = .paused }
        engine.seek(to: t, mode: .accurate)
        onTransportChange?()
    }

    func skip(by delta: Double) {
        seek(to: (scrubPosition ?? engine.currentTime) + delta)
    }

    /// Seek-bar dragging: cheap keyframe seeks while moving (throttled), one accurate seek on release.
    func scrub(to seconds: Double) {
        guard canControl else { return }
        let t = clamp(seconds)
        scrubPosition = t
        if Date().timeIntervalSince(lastScrubSeek) > 0.12 {
            lastScrubSeek = Date()
            engine.seek(to: t, mode: .keyframe)
        }
    }

    func endScrub(at seconds: Double) {
        let t = clamp(seconds)
        scrubPosition = nil
        seek(to: t)
    }

    func setSpeed(_ value: Float) {
        speed = value
        engine.setSpeed(value)
        showToast("Speed \(Self.speedLabel(value))")
        onTransportChange?()
    }

    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    static func speedLabel(_ v: Float) -> String {
        v == v.rounded() ? "\(Int(v))×" : String(format: "%g×", v)
    }

    // MARK: - Audio tracks

    func selectAudio(_ index: Int) {
        guard index != selectedAudioIndex, let track = audioTracks.first(where: { $0.index == index }) else { return }
        selectedAudioIndex = index
        engine.selectAudio(streamIndex: index)
        showToast("Audio: \(TrackLabels.menuTitle(track))")
        history?.record(identity: identity, url: url, title: url.deletingPathExtension().lastPathComponent,
                        position: engine.currentTime, duration: duration, audioStreamIndex: index)
    }

    /// A key: next audio track.
    func cycleAudio() {
        guard audioTracks.count > 1 else {
            if let only = audioTracks.first { showToast("Audio: \(TrackLabels.menuTitle(only))") }
            return
        }
        let i = audioTracks.firstIndex { $0.index == selectedAudioIndex } ?? -1
        selectAudio(audioTracks[(i + 1) % audioTracks.count].index)
    }

    // MARK: - History

    /// Saves the resume point (every 10 s of playback, and on pause / close / end).
    private func recordProgress(force: Bool = false) {
        guard let history, duration > 0, status != .opening else { return }
        let t = status == .ended ? duration : engine.currentTime
        guard force || abs(t - lastRecorded) >= 10 || status != .playing else { return }
        lastRecorded = t
        history.record(identity: identity, url: url, title: url.deletingPathExtension().lastPathComponent,
                       position: t, duration: duration)
    }

    func setVolume(_ value: Float) {
        volume = min(max(0, value), 1)
        engine.audioRenderer.volume = volume
        if volume > 0 && isMuted { setMuted(false) }
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        engine.audioRenderer.isMuted = muted
    }

    // MARK: - Subtitles

    @ObservationIgnored private var userChoseSubtitles = false

    /// Re-applies the subtitle choice made for this file last time.
    private func applySubtitlePreference() {
        if preferences.subtitlesOff {
            userChoseSubtitles = true
            selectedSubtitleID = nil
            subtitles?.select(nil)
        } else if let id = preferences.subtitleTrackID, subtitleTracks.contains(where: { $0.id == id }) {
            userChoseSubtitles = true
            selectedSubtitleID = id
            subtitles?.select(id)
        }
    }

    /// External files load in the background. One placed next to the video is shown
    /// automatically unless something else was already selected.
    private func subtitleTracksChanged() {
        subtitleTracks = subtitles?.tracks ?? []
        // A remembered external track can only be applied once its file has loaded.
        if !userChoseSubtitles, !preferences.subtitlesOff, let id = preferences.subtitleTrackID,
           subtitleTracks.contains(where: { $0.id == id }) {
            applySubtitlePreference()
            return
        }
        if selectedSubtitleID == nil, !userChoseSubtitles, let external = subtitleTracks.first(where: \.isExternal) {
            selectedSubtitleID = external.id
            subtitles?.select(external.id)
        }
    }

    func selectSubtitle(_ id: String?) {
        userChoseSubtitles = true
        history?.record(identity: identity, url: url, title: url.deletingPathExtension().lastPathComponent,
                        position: engine.currentTime, duration: duration, subtitleTrackID: .some(id))
        selectedSubtitleID = id
        subtitles?.select(id)
        let title = subtitleTracks.first { $0.id == id }?.menuTitle
        showToast(title.map { "Subtitles: \($0)" } ?? "Subtitles off")
    }

    /// S key: off → track 1 → track 2 … → off.
    func cycleSubtitles() {
        let ids: [String?] = [nil] + subtitleTracks.map(\.id)
        let current = ids.firstIndex(where: { $0 == selectedSubtitleID }) ?? 0
        selectSubtitle(ids[(current + 1) % ids.count])
    }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    func close() {
        recordProgress(force: true)
        history?.saveNow()
        sleepAssertion.release()
        volumeObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        volumeObservers.removeAll()
        engine.close()
    }

    /// When the drive holding the file is ejected or unplugged: release the file (so the eject
    /// isn't blocked by "in use") and say what happened instead of failing with a read error.
    private func observeVolumeUnmounts() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willUnmountNotification, NSWorkspace.didUnmountNotification] {
            volumeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
                MainActor.assumeIsolated { self?.volumeWillDisappear(volume) }
            })
        }
    }

    private func volumeWillDisappear(_ volume: URL) {
        let volumePath = volume.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard volumePath != "/", filePath.hasPrefix(volumePath.hasSuffix("/") ? volumePath : volumePath + "/") else { return }
        if case .failed = status { return }
        Log.playback.notice("Volume \(volumePath, privacy: .public) is going away; closing \(self.url.lastPathComponent, privacy: .public)")
        sleepAssertion.release()
        engine.close()
        status = .failed("The drive “\(volume.lastPathComponent)” was disconnected. Reconnect it and open the file again.")
        isBuffering = false
    }

    // MARK: - Engine events

    private var canControl: Bool {
        switch status {
        case .opening, .failed: return false
        default: return true
        }
    }

    private func handle(_ event: PlaybackEngine.Event) {
        switch event {
        case .opened(let media):
            self.media = media
            duration = media.duration
            videoRenderPath = media.videoRenderPath
            audioRenderPath = media.audioRenderPath
            subtitles = media.subtitles
            media.subtitles.onTracksChanged = { [weak self] in
                Task { @MainActor in self?.subtitleTracksChanged() }
            }
            subtitleTracks = media.subtitles.tracks
            selectedSubtitleID = media.defaultSubtitleID
            audioTracks = media.info.audioStreams
            selectedAudioIndex = media.audioStream?.index
            applySubtitlePreference()
            subtitleTracksChanged()
            onTransportChange?()
            status = wantsPlay ? .playing : .paused
            updateSleepAssertion()
            onOpened?(media)
        case .buffering(let buffering):
            isBuffering = buffering
        case .time(let t):
            if scrubPosition == nil { currentTime = min(t, duration > 0 ? duration : t) }
            if status == .playing { recordProgress() }
            if let r = resumedFrom, t > r + 8 { resumedFrom = nil }
        case .seekCompleted:
            break
        case .ended:
            currentTime = duration
            status = .ended
            updateSleepAssertion()
            recordProgress(force: true)
            onTransportChange?()
        case .failed(let message):
            status = .failed(message)
            isBuffering = false
            updateSleepAssertion()
        case .warning(let message):
            warning = message
        case .renderPaths(let video, let audio):
            videoRenderPath = video
            audioRenderPath = audio
        }
    }

    private func updateSleepAssertion() {
        if status == .playing { sleepAssertion.acquire() } else { sleepAssertion.release() }
    }

    private func clamp(_ t: Double) -> Double {
        duration > 0 ? min(max(0, t), duration) : max(0, t)
    }
}

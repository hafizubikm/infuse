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

    /// Called once the file is open (e.g. so the window can size itself to the video).
    var onOpened: ((PlaybackEngine.OpenedMedia) -> Void)?

    @ObservationIgnored private let engine: PlaybackEngine
    @ObservationIgnored private let sleepAssertion = DisplaySleepAssertion()
    @ObservationIgnored private var lastScrubSeek = Date.distantPast
    @ObservationIgnored private var wantsPlay = true
    @ObservationIgnored private var volumeObservers: [NSObjectProtocol] = []

    var isPlaying: Bool { status == .playing }
    var displayedTime: Double { scrubPosition ?? currentTime }

    init(url: URL) {
        self.url = url
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
        engine.open(startAt: startAt, autoplay: autoplay)
    }

    // MARK: - Transport

    func play() {
        guard canControl else { return }
        wantsPlay = true
        engine.play()
        status = .playing
        updateSleepAssertion()
    }

    func pause() {
        guard canControl else { return }
        wantsPlay = false
        engine.pause()
        status = .paused
        updateSleepAssertion()
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

    func close() {
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
            status = wantsPlay ? .playing : .paused
            updateSleepAssertion()
            onOpened?(media)
        case .buffering(let buffering):
            isBuffering = buffering
        case .time(let t):
            if scrubPosition == nil { currentTime = min(t, duration > 0 ? duration : t) }
        case .seekCompleted:
            break
        case .ended:
            currentTime = duration
            status = .ended
            updateSleepAssertion()
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

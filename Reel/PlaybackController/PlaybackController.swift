import Foundation
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

    /// Called once the file is open (e.g. so the window can size itself to the video).
    var onOpened: ((PlaybackEngine.OpenedMedia) -> Void)?

    @ObservationIgnored private let engine: PlaybackEngine
    @ObservationIgnored private let sleepAssertion = DisplaySleepAssertion()
    @ObservationIgnored private var lastScrubSeek = Date.distantPast
    @ObservationIgnored private var wantsPlay = true

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
        engine.close()
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
        }
    }

    private func updateSleepAssertion() {
        if status == .playing { sleepAssertion.acquire() } else { sleepAssertion.release() }
    }

    private func clamp(_ t: Double) -> Double {
        duration > 0 ? min(max(0, t), duration) : max(0, t)
    }
}

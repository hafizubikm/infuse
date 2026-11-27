import Foundation
import MediaPlayer

/// Media keys, AirPods stem/tap controls and the Now Playing widget, via MPRemoteCommandCenter
/// and MPNowPlayingInfoCenter (macOS requires `playbackState` to be set explicitly).
@MainActor
final class NowPlaying {
    private weak var controller: PlaybackController?
    private var targets: [(MPRemoteCommand, Any)] = []

    init(controller: PlaybackController) {
        self.controller = controller
        let center = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, _ handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            command.isEnabled = true
            targets.append((command, command.addTarget(handler: handler)))
        }
        add(center.togglePlayPauseCommand) { [weak self] _ in self?.run { $0.togglePlayPause() } ?? .noActionableNowPlayingItem }
        add(center.playCommand) { [weak self] _ in self?.run { $0.play() } ?? .noActionableNowPlayingItem }
        add(center.pauseCommand) { [weak self] _ in self?.run { $0.pause() } ?? .noActionableNowPlayingItem }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        add(center.skipForwardCommand) { [weak self] e in
            let s = (e as? MPSkipIntervalCommandEvent)?.interval ?? 10
            return self?.run { $0.skip(by: s) } ?? .noActionableNowPlayingItem
        }
        add(center.skipBackwardCommand) { [weak self] e in
            let s = (e as? MPSkipIntervalCommandEvent)?.interval ?? 10
            return self?.run { $0.skip(by: -s) } ?? .noActionableNowPlayingItem
        }
        // "Next/previous track" (e.g. double-tap on AirPods) skip 30 s, like Infuse.
        add(center.nextTrackCommand) { [weak self] _ in self?.run { $0.skip(by: 30) } ?? .noActionableNowPlayingItem }
        add(center.previousTrackCommand) { [weak self] _ in self?.run { $0.skip(by: -30) } ?? .noActionableNowPlayingItem }
        add(center.changePlaybackPositionCommand) { [weak self] e in
            guard let t = (e as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            return self?.run { $0.seek(to: t) } ?? .noActionableNowPlayingItem
        }
    }

    /// Remote commands arrive on the main thread.
    private nonisolated func run(_ action: @MainActor @escaping (PlaybackController) -> Void) -> MPRemoteCommandHandlerStatus {
        MainActor.assumeIsolated {
            guard let controller else { return .noActionableNowPlayingItem }
            action(controller)
            return .success
        }
    }

    func update() {
        guard let c = controller else { return }
        let info = MPNowPlayingInfoCenter.default()
        var dict: [String: Any] = [
            MPMediaItemPropertyTitle: c.url.deletingPathExtension().lastPathComponent,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: c.preciseTime,
            MPNowPlayingInfoPropertyPlaybackRate: c.isPlaying ? Double(c.speed) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if c.duration > 0 { dict[MPMediaItemPropertyPlaybackDuration] = c.duration }
        info.nowPlayingInfo = dict
        switch c.status {
        case .playing: info.playbackState = .playing
        case .paused, .ready, .opening: info.playbackState = .paused
        case .ended, .failed: info.playbackState = .stopped
        }
    }

    func tearDown() {
        for (command, target) in targets { command.removeTarget(target) }
        targets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}

import AVKit
import CoreMedia

/// Picture in Picture straight from the sample-buffer display layer (HDR and Dolby Vision are
/// kept; the subtitle overlay is not part of the PiP window).
@MainActor
final class PictureInPicture: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    private weak var controller: PlaybackController?
    private var pip: AVPictureInPictureController?

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    init(controller: PlaybackController) {
        self.controller = controller
        super.init()
        guard Self.isSupported else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: controller.videoLayer,
                                                                playbackDelegate: self)
        pip = AVPictureInPictureController(contentSource: source)
    }

    var isActive: Bool { pip?.isPictureInPictureActive ?? false }

    func toggle() {
        guard let pip else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }

    /// Call when play/pause/seek/duration change so the PiP controls stay current.
    func invalidate() { pip?.invalidatePlaybackState() }

    // MARK: - AVPictureInPictureSampleBufferPlaybackDelegate (called on the main thread)

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                setPlaying playing: Bool) {
        MainActor.assumeIsolated { playing ? controller?.play() : controller?.pause() }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        let duration: Double = MainActor.assumeIsolated { controller?.duration ?? 0 }
        return CMTimeRange(start: .zero, duration: CMTime(seconds: max(duration, 0.1), preferredTimescale: 600))
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        MainActor.assumeIsolated { !(controller?.isPlaying ?? false) }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        MainActor.assumeIsolated { controller?.skip(by: skipInterval.seconds) }
        completionHandler()
    }
}

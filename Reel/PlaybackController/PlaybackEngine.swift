import Foundation
import AVFoundation
import CoreMedia
import CFFmpeg

/// Plays one file: owns the demuxer, the feeders, the renderers and the render synchronizer
/// (audio clock is master). All state is confined to `queue`; events are delivered on main.
final class PlaybackEngine: @unchecked Sendable {
    enum SeekMode {
        /// Land exactly on the target (frames before it are decoded but not shown).
        case accurate
        /// Show the keyframe at or before the target (fast, used while scrubbing).
        case keyframe
    }

    enum Event {
        case opened(OpenedMedia)
        case buffering(Bool)
        case time(Double)
        case seekCompleted(Double)
        case ended
        case failed(String)
        case warning(String)
    }

    struct OpenedMedia {
        let info: MediaInfo
        let videoStream: StreamInfo?
        let audioStream: StreamInfo?
        let displaySize: CGSize?
        let videoRenderPath: String?
        let audioRenderPath: String?
        let duration: Double
    }

    let url: URL
    let videoRenderer: AVSampleBufferVideoRenderer
    let audioRenderer = AVSampleBufferAudioRenderer()
    let synchronizer = AVSampleBufferRenderSynchronizer()

    /// Delivered on the main queue.
    var onEvent: ((Event) -> Void)?

    private let queue = DispatchQueue(label: "Reel.PlaybackEngine", qos: .userInitiated)
    private var file: MediaFile?
    private var demuxer: Demuxer?
    private var videoFeeder: CompressedVideoFeeder?
    private var audioFeeder: AudioFeeding?
    private var duration: Double = 0
    private var desiredRate: Float = 0
    private var playbackSpeed: Float = 1
    private var generation = 0
    private var seekID = 0
    private var prerolling = false
    private var videoPrerolled = true
    private var audioPrerolled = true
    private var prerollTimeout: DispatchWorkItem?
    private var videoEnd: CMTime?
    private var audioEnd: CMTime?
    private var ended = false
    private var closed = false
    private var timeObserver: Any?
    private var notificationTokens: [NSObjectProtocol] = []

    init(url: URL, videoLayer: AVSampleBufferDisplayLayer) {
        self.url = url
        videoRenderer = videoLayer.sampleBufferRenderer
        audioRenderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        audioRenderer.audioTimePitchAlgorithm = .timeDomain
        synchronizer.addRenderer(audioRenderer)
        synchronizer.addRenderer(videoRenderer)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        observeRenderers()
    }

    deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    var currentTime: Double {
        let t = synchronizer.currentTime().seconds
        return t.isFinite ? max(0, t) : 0
    }

    // MARK: - Commands (thread-safe)

    func open(startAt: Double, autoplay: Bool) {
        queue.async { self.doOpen(startAt: startAt, autoplay: autoplay) }
    }

    func play() {
        queue.async {
            guard !self.closed else { return }
            self.desiredRate = self.playbackSpeed
            if self.ended {
                self.doSeek(to: 0, mode: .accurate)
            } else if !self.prerolling {
                self.synchronizer.rate = self.desiredRate
            }
        }
    }

    func pause() {
        queue.async {
            self.desiredRate = 0
            self.synchronizer.rate = 0
        }
    }

    func setSpeed(_ speed: Float) {
        queue.async {
            self.playbackSpeed = speed
            if self.desiredRate > 0 {
                self.desiredRate = speed
                if !self.prerolling { self.synchronizer.rate = speed }
            }
        }
    }

    func seek(to seconds: Double, mode: SeekMode) {
        queue.async { self.doSeek(to: seconds, mode: mode) }
    }

    func close() {
        queue.sync { self.doClose() }
    }

    // MARK: - Open

    private func doOpen(startAt: Double, autoplay: Bool) {
        do {
            let file = try MediaFile(url: url, useCustomIO: true)
            self.file = file
            let info = file.info
            duration = info.duration ?? 0
            let isMatroska = info.formatName.hasPrefix("matroska")

            let videoStream = TrackSelector.video(in: info)
            let audioStream = TrackSelector.audio(in: info)
            var active = Set<Int>()
            let demuxer = Demuxer(file: file)
            self.demuxer = demuxer

            var displaySize: CGSize?
            var videoPath: String?
            if let vs = videoStream, let st = file.stream(at: vs.index), let details = vs.video {
                do {
                    let format = try VideoFormatFactory.make(stream: st, details: details)
                    active.insert(vs.index)
                    demuxer.setActiveStreams(active)
                    let builder = VideoSampleBuilder(
                        format: format,
                        timing: StreamTimeConverter(timeBase: st.pointee.time_base, startTime: file.startTime),
                        frameRate: details.frameRate, isMatroska: isMatroska)
                    let feeder = CompressedVideoFeeder(renderer: videoRenderer, packets: demuxer.queue(for: vs.index)!,
                                                       builder: builder)
                    wire(feeder)
                    videoFeeder = feeder
                    displaySize = format.displaySize
                    videoPath = "\(format.renderDescription) · hardware decode"
                } catch {
                    emit(.warning("Video: \(error)"))
                    displaySize = VideoFormatFactory.displaySize(details)
                }
            }

            var audioPath: String?
            if let a = audioStream, let st = file.stream(at: a.index) {
                let par = st.pointee.codecpar.pointee
                if AudioFormatFactory.supportsPassthrough(codecID: par.codec_id) {
                    active.insert(a.index)
                    demuxer.setActiveStreams(active)
                    let feeder = PassthroughAudioFeeder(
                        renderer: audioRenderer, packets: demuxer.queue(for: a.index)!, codecpar: par,
                        timing: StreamTimeConverter(timeBase: st.pointee.time_base, startTime: file.startTime))
                    wire(feeder)
                    audioFeeder = feeder
                    audioPath = "\(a.codecDisplayName) passthrough · Apple decoder"
                } else {
                    emit(.warning("\(TrackLabels.audioFormat(a)) audio isn't supported yet; playing without sound."))
                }
            }
            demuxer.setActiveStreams(active)
            demuxer.onEvent = { [weak self] event in self?.queue.async { self?.handle(event) } }

            emit(.opened(OpenedMedia(info: info, videoStream: videoStream, audioStream: audioStream,
                                     displaySize: displaySize, videoRenderPath: videoPath,
                                     audioRenderPath: audioPath, duration: duration)))

            guard videoFeeder != nil || audioFeeder != nil else {
                emit(.failed("Reel can't play any stream in this file yet."))
                return
            }

            timeObserver = synchronizer.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 10), queue: queue) { [weak self] _ in self?.tick() }

            desiredRate = autoplay ? playbackSpeed : 0
            demuxer.start()
            let start = startAt > 1 && startAt < duration - 5 ? startAt : 0
            if start > 0 {
                doSeek(to: start, mode: .accurate)
            } else {
                synchronizer.setRate(0, time: .zero)
                startFeeders(generation: 0, target: .zero, mode: .accurate)
            }
        } catch {
            emit(.failed(String(describing: error)))
        }
    }

    private func wire(_ feeder: CompressedVideoFeeder) {
        feeder.onPrerolled = { [weak self] gen in self?.queue.async { self?.prerolled(video: true, generation: gen) } }
        feeder.onEndOfStream = { [weak self] gen, end in
            self?.queue.async { guard let self, gen == self.generation else { return }; self.videoEnd = end }
        }
        feeder.onError = { [weak self] error in self?.queue.async { self?.fail("Video decoding failed: \(error.localizedDescription)") } }
    }

    private func wire(_ feeder: AudioFeeding) {
        feeder.onPrerolled = { [weak self] gen in self?.queue.async { self?.prerolled(video: false, generation: gen) } }
        feeder.onEndOfStream = { [weak self] gen, end in
            self?.queue.async { guard let self, gen == self.generation else { return }; self.audioEnd = end }
        }
        feeder.onError = { [weak self] error in
            self?.queue.async {
                self?.emit(.warning("Audio stopped: \(error)"))
                self?.audioFeeder?.stop()
                self?.audioPrerolled = true
                self?.checkPreroll()
            }
        }
    }

    // MARK: - Seeking and preroll

    private func doSeek(to seconds: Double, mode: SeekMode) {
        guard let demuxer, !closed else { return }
        let target = min(max(0, seconds), max(0, duration - 0.05))
        seekID += 1
        let id = seekID
        synchronizer.rate = 0
        videoFeeder?.stop()
        audioFeeder?.stop()
        ended = false
        demuxer.seek(to: target) { [weak self] result in
            self?.queue.async {
                guard let self, id == self.seekID, !self.closed else { return }
                let t = CMTime(seconds: target, preferredTimescale: 90000)
                self.videoRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
                self.audioRenderer.flush()
                self.synchronizer.setRate(0, time: t)
                self.startFeeders(generation: result.generation, target: t, mode: mode)
                self.emit(.seekCompleted(target))
            }
        }
    }

    private func startFeeders(generation: Int, target: CMTime, mode: SeekMode) {
        self.generation = generation
        videoEnd = nil
        audioEnd = nil
        videoPrerolled = videoFeeder == nil
        audioPrerolled = audioFeeder == nil
        prerolling = true
        emit(.buffering(true))
        videoFeeder?.start(generation: generation, displayFrom: mode == .accurate ? target : .negativeInfinity)
        audioFeeder?.start(generation: generation, playFrom: target)

        prerollTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.prerolling, self.generation == generation else { return }
            Log.playback.notice("Preroll timed out; starting anyway")
            self.videoPrerolled = true
            self.audioPrerolled = true
            self.checkPreroll()
        }
        prerollTimeout = timeout
        queue.asyncAfter(deadline: .now() + 3, execute: timeout)
    }

    private func prerolled(video: Bool, generation: Int) {
        guard generation == self.generation else { return }
        if video { videoPrerolled = true } else { audioPrerolled = true }
        checkPreroll()
    }

    private func checkPreroll() {
        guard prerolling, videoPrerolled, audioPrerolled else { return }
        prerolling = false
        prerollTimeout?.cancel()
        emit(.buffering(false))
        if desiredRate > 0 { synchronizer.rate = desiredRate }
    }

    // MARK: - Time, end of file, errors

    private func tick() {
        guard !closed else { return }
        let now = synchronizer.currentTime()
        emit(.time(max(0, now.seconds)))
        guard !ended, !prerolling, synchronizer.rate > 0 else { return }
        let videoDone = videoFeeder == nil || videoEnd.map { CMTimeCompare(now, $0) >= 0 } == true
        let audioDone = audioFeeder == nil || audioEnd.map { CMTimeCompare(now, $0) >= 0 } == true
        if videoDone && audioDone {
            ended = true
            desiredRate = 0
            synchronizer.rate = 0
            emit(.ended)
        }
    }

    private func handle(_ event: Demuxer.Event) {
        switch event {
        case .endOfFile:
            break   // feeders report their own end once their queues drain
        case .error(let error):
            fail(error.description)
        }
    }

    private func fail(_ message: String) {
        guard !closed else { return }
        desiredRate = 0
        synchronizer.rate = 0
        emit(.failed(message))
    }

    private func observeRenderers() {
        let nc = NotificationCenter.default
        // Output device changes can make the audio renderer flush itself; re-feed from that point.
        notificationTokens.append(nc.addObserver(forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
                                                 object: audioRenderer, queue: nil) { [weak self] note in
            let flushTime = (note.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?.timeValue
            self?.queue.async {
                guard let self, !self.closed else { return }
                Log.audio.notice("Audio renderer flushed automatically; re-buffering")
                self.doSeek(to: flushTime?.seconds ?? self.currentTime, mode: .accurate)
            }
        })
        notificationTokens.append(nc.addObserver(forName: AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
                                                 object: videoRenderer, queue: nil) { [weak self] _ in
            self?.queue.async {
                guard let self, !self.closed, self.videoRenderer.requiresFlushToResumeDecoding else { return }
                Log.video.notice("Video renderer needs a flush; re-buffering")
                self.doSeek(to: self.currentTime, mode: .accurate)
            }
        })
    }

    private func doClose() {
        guard !closed else { return }
        closed = true
        prerollTimeout?.cancel()
        synchronizer.rate = 0
        if let timeObserver { synchronizer.removeTimeObserver(timeObserver) }
        timeObserver = nil
        videoFeeder?.stop()
        audioFeeder?.stop()
        demuxer?.stop()
        videoRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        audioRenderer.flush()
        videoFeeder = nil
        audioFeeder = nil
        demuxer = nil
        file = nil
    }

    private func emit(_ event: Event) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }
}

/// Picks the default tracks to play.
enum TrackSelector {
    static func video(in info: MediaInfo) -> StreamInfo? { info.primaryVideo }

    /// The default audio track; until FFmpeg-decoded audio exists (milestone 4), prefers a track
    /// macOS can decode itself when the default one can't be played.
    static func audio(in info: MediaInfo) -> StreamInfo? {
        guard let primary = info.primaryAudio else { return nil }
        let passthrough: Set<String> = ["aac", "ac3", "eac3"]
        if passthrough.contains(primary.codecName) { return primary }
        let candidates = info.audioStreams.filter { passthrough.contains($0.codecName) }
        return candidates.first(where: { $0.language == primary.language }) ?? candidates.first ?? primary
    }
}

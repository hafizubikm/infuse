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
        /// What is decoding/rendering video and audio changed (e.g. Dolby Vision fallback).
        case renderPaths(video: String?, audio: String?)
    }

    struct OpenedMedia {
        let info: MediaInfo
        let videoStream: StreamInfo?
        let audioStream: StreamInfo?
        let displaySize: CGSize?
        let videoRenderPath: String?
        let audioRenderPath: String?
        let duration: Double
        let subtitles: SubtitleManager
        /// The subtitle track chosen by default (forced in the audio language, or flagged default).
        let defaultSubtitleID: String?
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
    private var videoFeeder: VideoFeeding?
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
    private var videoStreamIndex: Int?
    private var videoDetails: VideoDetails?
    private var isMatroska = false
    private var triedBaseLayerFallback = false
    private var triedDecodedFallback = false
    private var handlingVideoFailure = false
    private var videoFailed = false
    private var videoPath: String?
    private var audioPath: String?
    private var activeStreams = Set<Int>()
    private var audioStreamIndex: Int?
    /// How multichannel audio is rendered (Apple Spatial Audio, Virtual Surround, stereo).
    private var rendering: AudioRendering = .spatial
    private var virtualSurroundRoom = false

    init(url: URL, videoLayer: AVSampleBufferDisplayLayer) {
        self.url = url
        videoRenderer = videoLayer.sampleBufferRenderer
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

    /// - Parameter preferredAudioStream: the audio stream chosen for this file last time.
    func open(startAt: Double, autoplay: Bool, preferredAudioStream: Int? = nil) {
        queue.async { self.doOpen(startAt: startAt, autoplay: autoplay, preferredAudioStream: preferredAudioStream) }
    }

    /// Switches to another audio track (restarts the audio path at the current position).
    func selectAudio(streamIndex: Int) {
        queue.async { self.doSelectAudio(streamIndex) }
    }

    /// Changes how audio is rendered; rebuilds the audio path at the current position if a
    /// track is playing (set before `open` to start that way).
    func setAudioRendering(_ rendering: AudioRendering, roomAmbience: Bool = false) {
        queue.async {
            guard rendering != self.rendering || roomAmbience != self.virtualSurroundRoom else { return }
            let roomOnly = rendering == self.rendering
            self.rendering = rendering
            self.virtualSurroundRoom = roomAmbience
            if roomOnly && rendering != .virtualSurround { return }
            guard !self.closed, let index = self.audioStreamIndex,
                  let stream = self.file?.info.audioStreams.first(where: { $0.index == index }) else { return }
            Log.audio.notice("Audio rendering → \(rendering.rawValue, privacy: .public)")
            self.rebuildAudio(stream)
        }
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

    private func doOpen(startAt: Double, autoplay: Bool, preferredAudioStream: Int?) {
        do {
            let file = try MediaFile(url: url, useCustomIO: true)
            self.file = file
            file.detectAudioFeatures()          // Atmos / DTS:X flags (decodes one frame, rewinds)
            let info = file.info
            duration = info.duration ?? 0
            isMatroska = info.formatName.hasPrefix("matroska")

            let videoStream = TrackSelector.video(in: info)
            let audioStream = preferredAudioStream.flatMap { p in info.audioStreams.first { $0.index == p } }
                ?? TrackSelector.audio(in: info)
            var active = Set<Int>()
            let demuxer = Demuxer(file: file)
            self.demuxer = demuxer

            var displaySize: CGSize?
            if let vs = videoStream, let details = vs.video {
                videoStreamIndex = vs.index
                videoDetails = details
                active.insert(vs.index)
                demuxer.setActiveStreams(active)
                displaySize = VideoFormatFactory.displaySize(details)
                let par = file.stream(at: vs.index)!.pointee.codecpar.pointee
                let useHardwarePath = VideoFormatFactory.supportsCompressedPath(codecID: par.codec_id)
                    && !VideoPathSelector.needsDecodedPath(vs)
                do {
                    if useHardwarePath {
                        do {
                            try setUpVideo(.compressed(.automatic))
                        } catch {
                            Log.video.notice("Hardware path unavailable (\(String(describing: error), privacy: .public)); decoding with FFmpeg")
                            triedDecodedFallback = true
                            try setUpVideo(.decoded)
                        }
                    } else {
                        triedDecodedFallback = true
                        try setUpVideo(.decoded)
                    }
                    displaySize = videoFeeder?.displaySize ?? displaySize
                } catch {
                    active.remove(vs.index)
                    emit(.warning("Video can't be decoded: \(error)"))
                }
            }

            if let a = audioStream {
                active.insert(a.index)
                demuxer.setActiveStreams(active)
                do {
                    try setUpAudio(a)
                } catch {
                    active.remove(a.index)
                    emit(.warning("\(TrackLabels.audioFormat(a)) audio can't be decoded (\(error)); playing without sound."))
                }
            }
            // Every subtitle stream is demuxed and decoded, so switching tracks is instant.
            let subtitles = SubtitleManager(file: file)
            active.formUnion(subtitles.embeddedStreamIndices)
            demuxer.setActiveStreams(active)
            activeStreams = active
            subtitles.attach(demuxer)
            subtitles.loadExternal(for: url)
            let defaultSubtitle = SubtitleSelector.defaultTrack(subtitles.tracks, audioLanguage: audioStream?.language)
            subtitles.select(defaultSubtitle?.id)
            demuxer.onEvent = { [weak self] event in self?.queue.async { self?.handle(event) } }

            emit(.opened(OpenedMedia(info: info, videoStream: videoStream, audioStream: audioStream,
                                     displaySize: displaySize, videoRenderPath: videoPath,
                                     audioRenderPath: audioPath, duration: duration,
                                     subtitles: subtitles, defaultSubtitleID: defaultSubtitle?.id)))

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

    /// Creates the audio feeder for `a` (its demuxer queue must exist).
    ///
    /// Apple Spatial Audio: passthrough for formats macOS decodes (AAC, AC-3, E-AC-3/Atmos),
    /// FFmpeg → multichannel PCM for everything else, spatialization allowed.
    /// Virtual Surround / Stereo: multichannel tracks (E-AC-3 included) are decoded by FFmpeg and
    /// rendered to stereo by Reel, with macOS spatialization off so nothing is processed twice.
    private func setUpAudio(_ a: StreamInfo) throws {
        guard let file, let demuxer, let st = file.stream(at: a.index), let packets = demuxer.queue(for: a.index) else { return }
        let par = st.pointee.codecpar.pointee
        let timing = StreamTimeConverter(timeBase: st.pointee.time_base, startTime: file.startTime)
        let format = TrackLabels.audioFormat(a)
        let multichannel = Int(par.ch_layout.nb_channels) > 2 || (a.audio?.channels ?? 0) > 2
        let bed = (a.audio?.isAtmos == true || a.audio?.isDTSX == true) ? " (channel bed; objects not decoded)" : ""

        var processor: AudioChannelProcessor?
        if multichannel {
            switch rendering {
            case .spatial: processor = nil
            case .virtualSurround: processor = BinauralVirtualizer(roomAmbience: virtualSurroundRoom)
            case .stereo: processor = StereoDownmixer()
            }
        }
        audioRenderer.allowedAudioSpatializationFormats = rendering == .spatial ? .monoStereoAndMultichannel : []
        let spatialNote = rendering == .spatial ? "Apple Spatial Audio" : "no spatial processing"

        if processor == nil, AudioFormatFactory.supportsPassthrough(codecID: par.codec_id) {
            let feeder = PassthroughAudioFeeder(renderer: audioRenderer, packets: packets, codecpar: par, timing: timing)
            wire(feeder)
            audioFeeder = feeder
            audioPath = "\(format) · decoded by macOS · \(spatialNote)"
        } else {
            let feeder = try PCMAudioFeeder(renderer: audioRenderer, packets: packets, stream: st,
                                            timing: timing, label: format, processor: processor)
            wire(feeder)
            audioFeeder = feeder
            if let processor {
                let output = processor is BinauralVirtualizer ? " → stereo" : ""
                audioPath = "\(format) · decoded by FFmpeg\(bed) → \(processor.name)\(output)"
            } else {
                let pcm = multichannel ? "multichannel PCM" : "PCM"
                audioPath = "\(format) · decoded by FFmpeg\(bed) → \(pcm) · \(spatialNote)"
            }
        }
        audioStreamIndex = a.index
    }

    private func doSelectAudio(_ index: Int) {
        guard !closed, let file, let demuxer, index != audioStreamIndex,
              let stream = file.info.audioStreams.first(where: { $0.index == index }) else { return }
        if let old = audioStreamIndex { activeStreams.remove(old) }
        activeStreams.insert(index)
        demuxer.setActiveStreams(activeStreams)
        rebuildAudio(stream)
    }

    /// Replaces the audio feeder (new track or rendering) and re-buffers at the current position.
    private func rebuildAudio(_ stream: StreamInfo) {
        let resumeAt = currentTime
        audioFeeder?.stop()
        audioFeeder = nil
        audioRenderer.flush()
        do {
            try setUpAudio(stream)
        } catch {
            emit(.warning("\(TrackLabels.audioFormat(stream)) audio can't be decoded (\(error))."))
        }
        emit(.renderPaths(video: videoPath, audio: audioPath))
        // After the end the next play() seeks to 0 and starts the feeders anyway.
        if !ended { doSeek(to: resumeAt, mode: .accurate) }
    }

    private enum VideoPath {
        /// Compressed samples to AVSampleBufferDisplayLayer (VideoToolbox hardware decode).
        case compressed(DolbyVisionPolicy)
        /// FFmpeg decode (VideoToolbox hwaccel where possible) → pixel buffers.
        case decoded
    }

    /// Creates the video feeder for the selected stream (again after a fallback).
    private func setUpVideo(_ path: VideoPath) throws {
        guard let file, let demuxer, let index = videoStreamIndex, let details = videoDetails,
              let st = file.stream(at: index), let packets = demuxer.queue(for: index) else { return }
        let timing = StreamTimeConverter(timeBase: st.pointee.time_base, startTime: file.startTime)
        let feeder: VideoFeeding
        switch path {
        case .compressed(let policy):
            let format = try VideoFormatFactory.make(stream: st, details: details, dolbyVision: policy)
            let builder = VideoSampleBuilder(format: format, timing: timing, frameRate: details.frameRate, isMatroska: isMatroska)
            feeder = CompressedVideoFeeder(renderer: videoRenderer, packets: packets, builder: builder)
        case .decoded:
            let stream = file.info.streams.first { $0.index == index }
            let label = stream.map(VideoPathSelector.label) ?? "Video"
            feeder = try DecodedVideoFeeder(renderer: videoRenderer, packets: packets, stream: st,
                                            details: details, timing: timing, label: label)
        }
        wire(feeder)
        videoFeeder = feeder
        videoPath = feeder.renderDescription
        Log.video.notice("Video path: \(self.videoPath ?? "", privacy: .public)")
    }

    /// The renderer rejected the video:
    /// 1. native Dolby Vision → retry once with the compatible base layer;
    /// 2. other hardware-path failures (e.g. 10-bit H.264) → retry once with FFmpeg decoding;
    /// 3. otherwise give up with a clear message.
    private func handleVideoFailure(_ error: Error) {
        guard !closed, !videoFailed else { return }
        let format = videoFeeder?.compressedFormat
        var next: VideoPath?
        var notice: String?
        if let format, format.canFallBackToBaseLayer, !triedBaseLayerFallback {
            triedBaseLayerFallback = true
            next = .compressed(.baseLayerOnly)
            notice = "This Mac couldn't render Dolby Vision for this file, so Reel is showing its HDR base layer."
        } else if format != nil, format?.dolbyVisionMode != .native, !triedDecodedFallback {
            triedDecodedFallback = true
            next = .decoded
            notice = "The hardware decoder rejected this video; Reel is decoding it with FFmpeg instead."
        }
        if let next {
            Log.video.error("Video path failed (\(String(describing: error), privacy: .public)); trying another path")
            let resumeAt = currentTime
            videoFeeder?.stop()
            videoRenderer.flush()
            do {
                try setUpVideo(next)
                emit(.renderPaths(video: videoPath, audio: audioPath))
                if let notice { emit(.warning(notice)) }
                doSeek(to: resumeAt, mode: .accurate)
                return
            } catch {
                Log.video.error("Fallback failed: \(String(describing: error), privacy: .public)")
            }
        }
        let dvHint = format?.dolbyVisionMode == .native && format?.canFallBackToBaseLayer == false
            ? " Dolby Vision Profile 5 has no HDR10 fallback layer." : ""
        videoFailed = true
        videoFeeder?.stop()
        fail("Video decoding failed: \(error.localizedDescription).\(dvHint)")
    }

    private func wire(_ feeder: VideoFeeding) {
        feeder.onDescriptionChanged = { [weak self] text in
            self?.queue.async {
                guard let self else { return }
                self.videoPath = text
                self.emit(.renderPaths(video: text, audio: self.audioPath))
            }
        }
        feeder.onPrerolled = { [weak self] gen in self?.queue.async { self?.prerolled(video: true, generation: gen) } }
        feeder.onEndOfStream = { [weak self] gen, end in
            self?.queue.async { guard let self, gen == self.generation else { return }; self.videoEnd = end }
        }
        feeder.onError = { [weak self, weak feeder] error in
            self?.queue.async {
                // Ignore late errors from a feeder that has already been replaced.
                guard let self, let feeder, feeder === self.videoFeeder else { return }
                self.handleVideoFailure(error)
            }
        }
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
        // The renderer can fail asynchronously (e.g. no Dolby Vision decoder) after it stops
        // asking for data, so the feeder may never see it; check here as well.
        if videoFeeder != nil, videoRenderer.status == .failed, !handlingVideoFailure {
            handlingVideoFailure = true
            handleVideoFailure(videoRenderer.error ?? VideoFormatError.coreMedia(-1))
            handlingVideoFailure = false
        }
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

    /// The default (or first) audio track — except that a default TrueHD Atmos track is swapped
    /// for an E-AC-3 Atmos track in the same language when the file has one: macOS renders the
    /// E-AC-3 Atmos objects for Spatial Audio, while FFmpeg only decodes TrueHD's 7.1 bed.
    static func audio(in info: MediaInfo) -> StreamInfo? {
        guard let primary = info.primaryAudio else { return nil }
        if primary.codecName == "truehd", primary.audio?.isAtmos == true,
           let eac3 = info.audioStreams.first(where: {
               $0.codecName == "eac3" && $0.audio?.isAtmos == true && $0.language == primary.language
           }) {
            return eac3
        }
        return primary
    }
}

/// Chooses between the hardware (compressed) and FFmpeg-decoded video paths.
enum VideoPathSelector {
    /// Streams VideoToolbox can't decode even though the codec is H.264/HEVC/AV1.
    static func needsDecodedPath(_ s: StreamInfo) -> Bool {
        guard let v = s.video else { return false }
        if s.codecName == "h264" {
            // 10-bit (Hi10P) and 4:2:2 / 4:4:4 H.264 have no hardware decoder on Apple Silicon.
            if (v.bitDepth ?? 8) > 8 { return true }
            if let pf = v.pixelFormat, pf.hasPrefix("yuv422") || pf.hasPrefix("yuv444") { return true }
        }
        return false
    }

    /// "VC-1", "MPEG-2", "H.264 High 10" …
    static func label(_ s: StreamInfo) -> String {
        var label = s.codecDisplayName
        if let profile = s.profileName, s.codecName == "h264" { label += " \(profile)" }
        if let hdr = s.video.flatMap(TrackLabels.hdrDescription) { label += " \(hdr)" }
        return label
    }
}

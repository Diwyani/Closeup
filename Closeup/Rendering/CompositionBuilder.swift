import AVFoundation
import CoreImage
import os

/// Holds the compositor the video pipeline is using, so the editor can swap
/// in new settings while the preview keeps playing. Frames are rendered on
/// background threads, hence the lock.
final class LiveCompositor: Sendable {
    private let state: OSAllocatedUnfairLock<FrameCompositor>

    init(_ compositor: FrameCompositor) {
        state = OSAllocatedUnfairLock(initialState: compositor)
    }

    var current: FrameCompositor {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// A recording assembled for AVFoundation: every file of the project placed
/// on one timeline (with cuts and speed-ups applied), plus how to draw and
/// mix it. Drives both the preview player and the exporter.
struct ProjectComposition {
    let asset: AVComposition
    let videoComposition: AVVideoComposition
    /// Length after cuts and speed-ups.
    let duration: CMTime
    let videoTracks: [AVCompositionTrack]
    let microphoneTrack: AVCompositionTrack?
    let systemAudioTrack: AVCompositionTrack?

    var audioTracks: [AVCompositionTrack] { [microphoneTrack, systemAudioTrack].compactMap { $0 } }

    /// The same composition drawn at another size (e.g. a new aspect ratio).
    func videoComposition(renderSize: CGSize) -> AVVideoComposition {
        let copy = videoComposition.mutableCopy() as! AVMutableVideoComposition
        copy.renderSize = renderSize
        return copy
    }

    /// Per-track volume (1 = as recorded).
    func audioMix(microphoneVolume: Double, systemVolume: Double) -> AVAudioMix? {
        guard !audioTracks.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [(microphoneTrack, microphoneVolume), (systemAudioTrack, systemVolume)]
            .compactMap { track, volume in
                guard let track else { return nil }
                let parameters = AVMutableAudioMixInputParameters(track: track)
                parameters.setVolume(Float(volume), at: .zero)
                return parameters
            }
        return mix
    }
}

/// A project's files, opened once. Assembling a timeline from them is then
/// quick, so it can be redone whenever the cuts change.
struct ProjectSources {
    struct Placed {
        let track: AVAssetTrack
        /// Where it sits on the recording's timeline, and which part of the file.
        let timelineStart: CMTime
        let fileRange: CMTimeRange
    }

    /// The opened files. A track only works while its asset is alive, so we
    /// hold on to them here.
    let assets: [AVAsset]
    let screen: AVAssetTrack
    /// The part of screen.mov that actually has frames (may start a little after 0).
    let screenRange: CMTimeRange
    let duration: CMTime
    let camera: Placed?
    let microphone: Placed?
    let systemAudio: Placed?
}

enum CompositionBuilder {
    /// `cleanMicrophone`: use microphone-clean.m4a (see AudioCleaner) when it exists.
    static func loadSources(
        project: RecordingProject, metadata: RecordingMetadata, cleanMicrophone: Bool = false
    ) async throws -> ProjectSources {
        // The screen recording defines the timeline.
        let screenAsset = AVURLAsset(url: project.videoURL)
        guard let screen = try await screenAsset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideoTrack }
        let duration = try await screenAsset.load(.duration)
        let screenRange = try await screen.load(.timeRange)
        let camera = try await place(metadata.camera, .video, of: project, duration: duration)
        var microphoneInfo = metadata.microphone
        if cleanMicrophone, FileManager.default.fileExists(atPath: project.cleanMicrophoneURL.path) {
            microphoneInfo?.file = project.cleanMicrophoneURL.lastPathComponent
        }
        let microphone = try await place(microphoneInfo, .audio, of: project, duration: duration)
        let systemAudio = try await place(metadata.systemAudio, .audio, of: project, duration: duration)
        return ProjectSources(
            assets: [screenAsset] + [camera, microphone, systemAudio].compactMap { $0?.asset },
            screen: screen,
            screenRange: screenRange,
            duration: duration,
            camera: camera?.placed,
            microphone: microphone?.placed,
            systemAudio: systemAudio?.placed)
    }

    static func make(
        sources: ProjectSources, edits: [TimeEdit], canvas: CGSize, fps: Int, compositor: LiveCompositor
    ) throws -> ProjectComposition {
        let composition = AVMutableComposition()
        func add(_ mediaType: AVMediaType, _ placed: ProjectSources.Placed?) throws -> AVMutableCompositionTrack? {
            guard let placed, let track = composition.addMutableTrack(withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { return nil }
            try track.insertTimeRange(placed.fileRange, of: placed.track, at: placed.timelineStart)
            return track
        }

        guard let screenTrack = try add(.video, ProjectSources.Placed(
            track: sources.screen, timelineStart: sources.screenRange.start, fileRange: sources.screenRange))
        else { throw ExportError.noVideoTrack }
        // Extras never stop a recording from opening: skip any that won't load.
        let cameraTrack = (try? add(.video, sources.camera)) ?? nil
        let microphoneTrack = (try? add(.audio, sources.microphone)) ?? nil
        let systemAudioTrack = (try? add(.audio, sources.systemAudio)) ?? nil

        // Apply cuts and speed-ups from the end backwards, so earlier times
        // stay where they are while we work.
        for edit in TimeMap(edits: edits, duration: sources.duration.seconds).edits.reversed() {
            let range = CMTimeRange(
                start: CMTime(seconds: edit.start, preferredTimescale: 90_000),
                end: CMTime(seconds: edit.end, preferredTimescale: 90_000))
            switch edit.kind {
            case .cut:
                composition.removeTimeRange(range)
            case .speed:
                composition.scaleTimeRange(range, toDuration: CMTimeMultiplyByFloat64(range.duration, multiplier: 1 / max(edit.speed, 1)))
            }
        }
        let duration = composition.duration

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = StudioVideoCompositor.self
        videoComposition.instructions = [StudioInstruction(
            timeRange: CMTimeRange(start: .zero, duration: duration),
            screenTrackID: screenTrack.trackID,
            cameraTrackID: cameraTrack?.trackID,
            compositor: compositor)]
        videoComposition.renderSize = canvas
        // A steady frame rate, even where the raw recording has gaps (a still
        // screen), so the cursor and zoom keep moving.
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        videoComposition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        return ProjectComposition(
            asset: composition,
            videoComposition: videoComposition,
            duration: duration,
            videoTracks: [screenTrack, cameraTrack].compactMap { $0 },
            microphoneTrack: microphoneTrack,
            systemAudioTrack: systemAudioTrack)
    }

    /// Works out where an extra file sits on the timeline (its recorded
    /// offset), trimmed to the screen recording's length.
    private static func place(
        _ info: RecordingMetadata.MediaTrack?, _ mediaType: AVMediaType,
        of project: RecordingProject, duration: CMTime
    ) async throws -> (asset: AVAsset, placed: ProjectSources.Placed)? {
        guard let info else { return nil }
        let asset = AVURLAsset(url: project.folder.appending(path: info.file))
        guard let track = try await asset.loadTracks(withMediaType: mediaType).first else { return nil }
        let fileLength = try await asset.load(.duration).seconds

        // offset < 0: the file started before the screen, so skip its start.
        let timelineStart = max(0, info.offset)
        let fileStart = timelineStart - info.offset
        let length = min(fileLength - fileStart, duration.seconds - timelineStart)
        guard length > 0.05 else { return nil }

        let timescale: CMTimeScale = 90_000
        return (asset, ProjectSources.Placed(
            track: track,
            timelineStart: CMTime(seconds: timelineStart, preferredTimescale: timescale),
            fileRange: CMTimeRange(
                start: CMTime(seconds: fileStart, preferredTimescale: timescale),
                duration: CMTime(seconds: length, preferredTimescale: timescale))))
    }
}

// MARK: - Custom compositor

/// Tells StudioVideoCompositor which tracks are the screen and the camera,
/// and which FrameCompositor draws them.
final class StudioInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {  // immutable after init
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    /// Frames change even when no source changes (the cursor moves), so
    /// AVFoundation must never reuse an old frame.
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID?
    let compositor: LiveCompositor

    init(timeRange: CMTimeRange, screenTrackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID?, compositor: LiveCompositor) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.compositor = compositor
        requiredSourceTrackIDs = [screenTrackID, cameraTrackID].compactMap { $0 }.map { NSNumber(value: $0) }
        super.init()
    }
}

/// AVFoundation calls this for every output frame with the matching screen
/// and camera frames; we draw them with FrameCompositor on the GPU.
final class StudioVideoCompositor: NSObject, AVVideoCompositing {
    /// Renders on the GPU (Core Image uses Metal under the hood).
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard
            let instruction = request.videoCompositionInstruction as? StudioInstruction,
            let screenBuffer = request.sourceFrame(byTrackID: instruction.screenTrackID),
            let output = request.renderContext.newPixelBuffer()
        else {
            request.finish(with: NSError(domain: "Closeup", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Missing frame for compositing",
            ]))
            return
        }

        // The camera may not cover every moment (it can start a bit late).
        let camera = instruction.cameraTrackID
            .flatMap { request.sourceFrame(byTrackID: $0) }
            .map { CIImage(cvPixelBuffer: $0) }

        let size = request.renderContext.size
        let frame = instruction.compositor.current.render(
            source: CIImage(cvPixelBuffer: screenBuffer),
            camera: camera,
            at: request.compositionTime.seconds,
            canvas: size)
        Self.context.render(frame, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: Self.colorSpace)
        request.finish(withComposedVideoFrame: output)
    }
}

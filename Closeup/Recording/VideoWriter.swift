import AVFoundation
import os

/// Encodes captured frames into a .mov file with AVAssetWriter.
///
/// Not thread-safe on purpose: everything runs on the capture queue it's
/// given. That's the simplest way to keep AVAssetWriter happy, since it isn't
/// thread-safe either.
final class VideoWriter: @unchecked Sendable {
    struct Summary {
        /// Host-clock seconds of the first frame. Time zero for the cursor log.
        let firstFrameTime: Double
        let endTime: Double
        let frameCount: Int
        let droppedFrameCount: Int
        var duration: Double { endTime - firstFrameTime }
    }

    private let assetWriter: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let queue: DispatchQueue

    private var firstFrameTime: CMTime?
    private var lastFrameTime: CMTime?
    private var frameCount = 0
    private var droppedFrameCount = 0
    private var isFinishing = false

    /// Safety net: in real-time mode AVAssetWriter keeps accepting frames even
    /// when the encoder falls behind, and every waiting frame is held in memory.
    /// Above this budget we drop frames until the encoder catches up.
    private static let memoryBudget: UInt64 = 2_000_000_000
    private static let memoryResume: UInt64 = 1_500_000_000
    private var isDroppingForMemory = false

    init(url: URL, width: Int, height: Int, fps: Int, queue: DispatchQueue) throws {
        self.queue = queue
        assetWriter = try AVAssetWriter(outputURL: url, fileType: .mov)

        // HEVC rather than H.264: H.264's hardware encoder tops out around 4K,
        // and a 5K/6K display recorded at native size would fail.
        // The bitrate is generous because export may zoom in 2× or more.
        let bitrate = Double(width * height * fps) * 0.1
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
                // A keyframe every second keeps scrubbing fast in the editor later.
                AVVideoMaxKeyFrameIntervalKey: fps,
                AVVideoAllowFrameReorderingKey: false,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)

        guard assetWriter.canAdd(input) else { throw RecordingError.writerSetupFailed }
        assetWriter.add(input)
        guard assetWriter.startWriting() else {
            throw assetWriter.error ?? RecordingError.writerSetupFailed
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isFinishing, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        // Once the file has failed (disk full, drive unplugged) nothing more can be written.
        guard assetWriter.status == .writing else {
            droppedFrameCount += 1
            return
        }

        let time = sampleBuffer.presentationTimeStamp
        if firstFrameTime == nil {
            // The video timeline starts at the first frame we actually got.
            assetWriter.startSession(atSourceTime: time)
            firstFrameTime = time
            Logger.recording.info("First frame received")
        }
        guard input.isReadyForMoreMediaData, time > (lastFrameTime ?? .negativeInfinity), !isOverMemoryBudget() else {
            droppedFrameCount += 1
            return
        }
        if adaptor.append(pixelBuffer, withPresentationTime: time) {
            frameCount += 1
            lastFrameTime = time
        } else {
            droppedFrameCount += 1
        }
    }

    private func isOverMemoryBudget() -> Bool {
        let footprint = MemoryFootprint.bytes
        if isDroppingForMemory, footprint < Self.memoryResume {
            isDroppingForMemory = false
            Logger.recording.notice("Memory back to normal, recording frames again")
        } else if !isDroppingForMemory, footprint > Self.memoryBudget {
            isDroppingForMemory = true
            Logger.recording.error("Encoder is falling behind (\(footprint / 1_000_000) MB used), dropping frames")
        }
        return isDroppingForMemory
    }

    #if CLOSEUP_TESTS
    /// Tests only: puts the file in the state a full disk would.
    func breakForTesting() {
        queue.sync { assetWriter.cancelWriting() }
    }
    #endif

    /// Closes the file. `endTime` is the host-clock moment the user pressed stop.
    func finish(at endTime: Double) async throws -> Summary {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                isFinishing = true
                guard let firstFrameTime, let lastFrameTime else {
                    assetWriter.cancelWriting()
                    continuation.resume(throwing: RecordingError.noFramesCaptured)
                    return
                }
                // If the file already failed while recording, say so. (Finishing
                // a failed file is a programming error that would crash the app.)
                guard assetWriter.status == .writing else {
                    Logger.recording.error("Writer failed while recording: \(String(describing: self.assetWriter.error), privacy: .public)")
                    continuation.resume(throwing: assetWriter.error ?? RecordingError.writerFailed)
                    return
                }
                input.markAsFinished()
                // Hold the last frame until the moment stop was pressed, so the
                // video is exactly as long as the cursor log.
                let end = max(CMTime(seconds: endTime, preferredTimescale: 1_000_000_000), lastFrameTime)
                assetWriter.endSession(atSourceTime: end)
                assetWriter.finishWriting { [self] in
                    guard assetWriter.status == .completed else {
                        Logger.recording.error("Writer failed: \(String(describing: self.assetWriter.error), privacy: .public)")
                        continuation.resume(throwing: assetWriter.error ?? RecordingError.writerFailed)
                        return
                    }
                    Logger.recording.info("Video file finished: \(self.frameCount) frames, \(self.droppedFrameCount) dropped")
                    continuation.resume(returning: Summary(
                        firstFrameTime: firstFrameTime.seconds,
                        endTime: end.seconds,
                        frameCount: frameCount,
                        droppedFrameCount: droppedFrameCount))
                }
            }
        }
    }
}

enum RecordingError: LocalizedError {
    case noFramesCaptured
    case writerSetupFailed
    case writerFailed
    case noSourceSelected
    case cameraAccessDenied
    case microphoneAccessDenied

    var errorDescription: String? {
        switch self {
        case .cameraAccessDenied:
            "Closeup can't use the camera. Turn it on in System Settings → Privacy & Security → Camera, or pick “No camera”."
        case .microphoneAccessDenied:
            "Closeup can't use the microphone. Turn it on in System Settings → Privacy & Security → Microphone, or pick “No microphone”."
        case .noFramesCaptured: "No frames were captured."
        case .writerSetupFailed: "Couldn't set up the video file."
        case .writerFailed: "Couldn't finish writing the video file."
        case .noSourceSelected: "Pick a display or window to record first."
        }
    }
}

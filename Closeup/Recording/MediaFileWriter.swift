import AVFoundation
import os

/// Writes one camera or audio stream to its own file.
///
/// The writer is set up from the first sample that arrives, because only then
/// do we know the camera's size or the mic's channel count. Like VideoWriter,
/// it runs entirely on the queue its samples are delivered on.
final class MediaFileWriter: @unchecked Sendable {
    private let url: URL
    private let fileType: AVFileType
    private let mediaType: AVMediaType
    private let queue: DispatchQueue
    private let makeSettings: (CMFormatDescription) -> [String: Any]

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    /// Host-clock seconds of the first sample, i.e. the file's time zero.
    private var firstHostTime: Double?
    private var isFinishing = false
    private var failed = false

    init(
        url: URL, fileType: AVFileType, mediaType: AVMediaType, queue: DispatchQueue,
        settings: @escaping (CMFormatDescription) -> [String: Any]
    ) {
        self.url = url
        self.fileType = fileType
        self.mediaType = mediaType
        self.queue = queue
        makeSettings = settings
    }

    /// `hostTime` is the sample's time on the host clock (the one the screen uses).
    func append(_ sampleBuffer: CMSampleBuffer, hostTime: CMTime) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isFinishing, !failed, sampleBuffer.isValid, let format = sampleBuffer.formatDescription else { return }

        if writer == nil {
            do {
                let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
                let input = AVAssetWriterInput(mediaType: mediaType, outputSettings: makeSettings(format), sourceFormatHint: format)
                input.expectsMediaDataInRealTime = true
                writer.add(input)
                guard writer.startWriting() else { throw writer.error ?? RecordingError.writerSetupFailed }
                writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
                self.writer = writer
                self.input = input
                firstHostTime = hostTime.seconds
            } catch {
                failed = true
                Logger.recording.error("Couldn't write \(self.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        guard let input, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    /// Closes the file and returns its start on the host clock, or nil if
    /// nothing was written (the file is then deleted).
    func finish() async -> Double? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                isFinishing = true
                guard let writer, let input, writer.status == .writing else {
                    if let error = writer?.error {
                        Logger.recording.error("\(self.url.lastPathComponent, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    } else if writer == nil {
                        Logger.recording.error("\(self.url.lastPathComponent, privacy: .public): no samples arrived")
                    }
                    writer?.cancelWriting()
                    try? FileManager.default.removeItem(at: url)
                    continuation.resume(returning: nil)
                    return
                }
                input.markAsFinished()
                writer.finishWriting { [self] in
                    continuation.resume(returning: writer.status == .completed ? firstHostTime : nil)
                }
            }
        }
    }

    // MARK: Settings

    /// H.264 at the camera's own size.
    static func cameraSettings(_ format: CMFormatDescription) -> [String: Any] {
        let size = CMVideoFormatDescriptionGetDimensions(format)
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000],
        ]
    }

    /// AAC at the source's sample rate, mono or stereo.
    static func audioSettings(_ format: CMFormatDescription) -> [String: Any] {
        let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        let channels = min(2, max(1, Int(description?.mChannelsPerFrame ?? 1)))
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: description?.mSampleRate ?? 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 128_000 : 192_000,
        ]
    }
}

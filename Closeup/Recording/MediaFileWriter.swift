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
                // In one-second pieces, so a crash doesn't lose the file (see VideoWriter).
                writer.movieFragmentInterval = CMTime(value: 1, timescale: 1)
                let settings = makeSettings(format)
                // Ask first: making an input with settings the encoder can't
                // do is a crash, not an error we could catch.
                guard writer.canApply(outputSettings: settings, forMediaType: mediaType) else {
                    throw RecordingError.writerSetupFailed
                }
                let input = AVAssetWriterInput(mediaType: mediaType, outputSettings: settings, sourceFormatHint: format)
                input.expectsMediaDataInRealTime = true
                guard writer.canAdd(input) else { throw RecordingError.writerSetupFailed }
                writer.add(input)
                guard writer.startWriting() else { throw writer.error ?? RecordingError.writerSetupFailed }
                writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
                self.writer = writer
                self.input = input
                firstHostTime = hostTime.seconds
                RecordingRecovery.noteStart(of: url, hostTime: hostTime.seconds)
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
                    try? FileManager.default.removeItem(at: RecordingProject.startTimeURL(for: url))
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

    /// What the camera file spends per second. A 720p face in a bubble
    /// doesn't need more; at twice this the camera file was often bigger
    /// than the screen recording next to it.
    static let cameraBitrate = 3_000_000

    /// H.264 at the camera's own size.
    static func cameraSettings(_ format: CMFormatDescription) -> [String: Any] {
        let size = CMVideoFormatDescriptionGetDimensions(format)
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: cameraBitrate],
        ]
    }

    /// AAC, mono or stereo, at the source's sample rate where AAC allows it.
    static func audioSettings(_ format: CMFormatDescription) -> [String: Any] {
        let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        return audioSettings(
            sampleRate: description?.mSampleRate ?? 48_000, channels: Int(description?.mChannelsPerFrame ?? 1))
    }

    /// - Above 48 kHz (studio audio interfaces at 88.2, 96 or 192 kHz): recorded
    ///   at 48 kHz, the most AAC handles. Asking for more crashed the app.
    /// - Below 44.1 kHz (Bluetooth headsets use 16 or 24 kHz): the usual
    ///   bitrate isn't allowed there and the file failed to start, so the
    ///   encoder picks its own.
    static func audioSettings(sampleRate: Double, channels sourceChannels: Int) -> [String: Any] {
        let channels = min(2, max(1, sourceChannels))
        let rate = sampleRate > 0 ? min(sampleRate, 48_000) : 48_000
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
        ]
        if rate >= 44_100 { settings[AVEncoderBitRateKey] = channels == 1 ? 128_000 : 192_000 }
        return settings
    }
}

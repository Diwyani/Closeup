import os
import ScreenCaptureKit

/// Pulls frames (and optionally system audio) out of ScreenCaptureKit and
/// hands them to their writers.
///
/// Frames arrive on `sampleQueue`, a background serial queue, so the main
/// thread (and the UI) never waits on video work. Audio has its own queue.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Summary {
        let video: VideoWriter.Summary
        /// Host-clock seconds where system-audio.m4a starts; nil if none.
        let systemAudioStart: Double?
    }

    private let sampleQueue = DispatchQueue(label: "app.closeup.capture", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "app.closeup.system-audio", qos: .userInitiated)
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private let writer: VideoWriter
    private let audioWriter: MediaFileWriter?
    private var stream: SCStream?
    /// Set when the system ends capture by itself. Only touched on `sampleQueue`.
    private var stoppedBySystem = false

    /// Called if capture ends on its own: the window closed, or the user
    /// clicked "Stop" in the system's screen-sharing menu.
    var onUnexpectedStop: (@Sendable (Error) -> Void)?

    /// Pass `systemAudioURL` to also record what the Mac plays.
    init(target: CaptureTarget, fps: Int, outputURL: URL, systemAudioURL: URL?) throws {
        filter = target.filter
        configuration = target.streamConfiguration(fps: fps, capturesAudio: systemAudioURL != nil)
        writer = try VideoWriter(
            url: outputURL, width: target.pixelWidth, height: target.pixelHeight,
            fps: fps, queue: sampleQueue)
        let audioQueue = audioQueue
        audioWriter = systemAudioURL.map {
            MediaFileWriter(url: $0, fileType: .m4a, mediaType: .audio, queue: audioQueue, settings: MediaFileWriter.audioSettings)
        }
        super.init()
    }

    func start() async throws {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if audioWriter != nil {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try await stream.startCapture()
        self.stream = stream
        Logger.recording.info("Capture started")
    }

    func stop(at endTime: Double) async throws -> Summary {
        // Asking an already-stopped stream to stop can wait forever, so only
        // stop it if the system hasn't done so already.
        let alreadyStopped = sampleQueue.sync { stoppedBySystem }
        if let stream, !alreadyStopped {
            Logger.recording.info("Stopping capture…")
            try? await stream.stopCapture()
        }
        stream = nil
        Logger.recording.info("Capture stopped, finishing file…")
        let systemAudioStart = await audioWriter?.finish()
        return Summary(video: try await writer.finish(at: endTime), systemAudioStart: systemAudioStart)
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            guard sampleBuffer.isValid, Self.isCompleteFrame(sampleBuffer) else { return }
            writer.append(sampleBuffer)
        case .audio:
            // ScreenCaptureKit audio is already on the host clock.
            audioWriter?.append(sampleBuffer, hostTime: sampleBuffer.presentationTimeStamp)
        default:
            break
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Logger.recording.notice("System stopped capture: \(error.localizedDescription, privacy: .public)")
        sampleQueue.async { [self] in
            stoppedBySystem = true
            onUnexpectedStop?(error)
        }
    }

    /// ScreenCaptureKit also sends "nothing changed" and "blank" buffers with
    /// no image. Only `.complete` frames carry new pixels.
    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus)
        else { return false }
        return status == .complete
    }
}

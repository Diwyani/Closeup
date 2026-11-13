import AVFoundation

/// One-click shape and size for where the video will be posted.
enum ExportPreset: String, CaseIterable, Identifiable {
    case youtube, x, linkedIn, vertical

    var id: Self { self }

    var title: String {
        switch self {
        case .youtube: "YouTube · 16:9, 4K"
        case .x: "X · 16:9, 1080p"
        case .linkedIn: "LinkedIn · 1:1, 1080p"
        case .vertical: "Shorts, Reels, TikTok · 9:16, 1080p"
        }
    }

    var aspect: ExportStyle.Aspect {
        switch self {
        case .youtube, .x: .wide
        case .linkedIn: .square
        case .vertical: .vertical
        }
    }

    var resolution: ExportResolution { self == .youtube ? .uhd4K : .hd1080 }
}

enum ExportResolution: String, CaseIterable, Identifiable, Sendable {
    case hd720 = "720p"
    case hd1080 = "1080p"
    case uhd4K = "4K"

    var id: Self { self }

    /// Short side of the video: 720, 1080 or 2160 pixels.
    var shortSide: Double {
        switch self {
        case .hd720: 720
        case .hd1080: 1080
        case .uhd4K: 2160
        }
    }

    /// Output size for a shape, e.g. 1080p 16:9 = 1920×1080, 9:16 = 1080×1920.
    func size(for aspect: ExportStyle.Aspect) -> CGSize {
        let long = (shortSide * max(aspect.ratio, 1 / aspect.ratio) / 2).rounded() * 2  // even
        return aspect.ratio >= 1 ? CGSize(width: long, height: shortSide) : CGSize(width: shortSide, height: long)
    }

    /// Bits per second at 60 fps. Generous, because screen text shows
    /// compression artefacts quickly.
    var bitrate: Int {
        switch self {
        case .hd720: 10_000_000
        case .hd1080: 20_000_000
        case .uhd4K: 60_000_000
        }
    }
}

enum ExportError: LocalizedError {
    case noVideoTrack
    case readFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The recording has no video."
        case .readFailed: "Couldn't read the recording."
        case .writeFailed: "Couldn't write the exported video."
        }
    }
}

/// Renders every frame of a recording and writes an H.264 MP4 with AAC audio.
///
///     AVAssetReader (all project files + our composition + audio mix)
///         → finished frames and mixed audio
///         → AVAssetWriter (H.264 + AAC) → .mp4
///
/// The reader runs frames through the same composition the preview uses, so
/// the export matches what you saw and heard.
enum VideoExporter {
    static let fps = 60

    /// Exports into the recording's folder, replacing an earlier export at
    /// the same resolution once the new one is finished. `progress` gets 0…1 from a background thread.
    static func export(
        project: RecordingProject,
        metadata: RecordingMetadata,
        compositor: FrameCompositor,
        resolution: ExportResolution,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let canvas = resolution.size(for: compositor.style.aspect)
        let sources = try await CompositionBuilder.loadSources(
            project: project, metadata: metadata, cleanMicrophone: compositor.style.cleansAudio)
        let timeMap = compositor.timeMap ?? TimeMap(edits: [], duration: sources.duration.seconds)
        let built = try CompositionBuilder.make(
            sources: sources, edits: timeMap.edits, canvas: canvas, fps: fps,
            compositor: LiveCompositor(compositor))
        // Only the trimmed part is exported (trim is in recording time; the
        // composition runs in output time, after cuts and speed-ups).
        let trimStart = timeMap.output(at: max(0, compositor.style.trimStart))
        let trimEnd = timeMap.output(at: compositor.style.trimEnd ?? sources.duration.seconds)
        let duration = max(0.01, trimEnd - trimStart)
        let reader = try AVAssetReader(asset: built.asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: trimStart, preferredTimescale: 600),
            end: CMTime(seconds: trimEnd, preferredTimescale: 600))

        // Video: finished frames, drawn by our compositor.
        // (Reader outputs and writer inputs are only touched from their export
        // queue once pumping starts, so they're safe to share.)
        nonisolated(unsafe) let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: built.videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOutput.videoComposition = built.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw ExportError.readFailed }
        reader.add(videoOutput)

        // Audio: mic and system audio mixed into one stereo track.
        nonisolated(unsafe) var audioOutput: AVAssetReaderAudioMixOutput?
        if !built.audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: built.audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            output.audioTimePitchAlgorithm = .spectral  // sped-up voices keep their pitch
            output.audioMix = built.audioMix(
                microphoneVolume: compositor.style.microphoneVolume, systemVolume: compositor.style.systemVolume)
            guard reader.canAdd(output) else { throw ExportError.readFailed }
            reader.add(output)
            audioOutput = output
        }

        // Writer: H.264 + AAC, the formats every app and site accepts.
        // Written under a working name first, so an earlier export stays where
        // it is until the new one is completely finished.
        let finalURL = project.exportURL(for: resolution.rawValue)
        let url = project.folder.appending(path: ".Exporting \(resolution.rawValue).mp4")
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true  // playable while still downloading
        nonisolated(unsafe) let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: canvas.width,
            AVVideoHeightKey: canvas.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: resolution.bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw ExportError.writeFailed }
        writer.add(videoInput)

        nonisolated(unsafe) var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw ExportError.writeFailed }
            writer.add(input)
            audioInput = input
        }

        guard reader.startReading() else { throw reader.error ?? ExportError.readFailed }
        guard writer.startWriting() else {
            try? FileManager.default.removeItem(at: url)
            throw writer.error ?? ExportError.writeFailed
        }
        writer.startSession(atSourceTime: CMTime(seconds: trimStart, preferredTimescale: 600))

        // Pump video and audio side by side, as fast as the encoders accept them.
        await withTaskCancellationHandler {
            async let video: Void = pump(videoOutput, into: videoInput, label: "video") { sample in
                progress(min(1, max(0, sample.presentationTimeStamp.seconds - trimStart) / duration))
            }
            async let audio: Void = {
                if let audioOutput, let audioInput { await pump(audioOutput, into: audioInput, label: "audio") }
            }()
            _ = await (video, audio)
        } onCancel: {
            reader.cancelReading()
        }

        if Task.isCancelled || reader.status == .cancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        }
        if reader.status == .failed || writer.status == .failed {
            let error = reader.error ?? writer.error
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error ?? ExportError.writeFailed
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw writer.error ?? ExportError.writeFailed
        }
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: url, to: finalURL)
        progress(1)
        return finalURL
    }

    /// Moves samples from a reader output to a writer input until the output
    /// runs dry (done, cancelled or failed; the caller checks which).
    private static func pump(
        _ output: AVAssetReaderOutput, into input: AVAssetWriterInput, label: String,
        onSample: @escaping (CMSampleBuffer) -> Void = { _ in }
    ) async {
        nonisolated(unsafe) let output = output
        nonisolated(unsafe) let input = input
        let queue = DispatchQueue(label: "app.closeup.export.\(label)")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer(), input.append(sample) else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    onSample(sample)
                }
            }
        }
    }
}

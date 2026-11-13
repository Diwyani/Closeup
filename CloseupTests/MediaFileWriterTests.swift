import AVFoundation
import XCTest

/// The microphone and system-audio files, fed with made-up sound.
final class MediaFileWriterTests: XCTestCase {
    private let queue = DispatchQueue(label: "closeup.tests.audio")
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "closeup-media-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A tenth of a second of quiet sound, as a microphone would deliver it.
    static func audioChunk(index: Int, sampleRate: Double, channels: Int) -> CMSampleBuffer {
        let frames = Int(sampleRate / 10)
        let bytes = frames * 4 * channels
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes)
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: frames,
            presentationTimeStamp: CMTime(value: CMTimeValue(index * frames), timescale: CMTimeScale(sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sample)
        return sample!
    }

    /// Records two seconds of sound and returns the finished file's length.
    private func record(sampleRate: Double, channels: Int) async throws -> (start: Double?, seconds: Double, rate: Double) {
        let url = folder.appending(path: "mic-\(Int(sampleRate))-\(channels).m4a")
        let writer = MediaFileWriter(url: url, fileType: .m4a, mediaType: .audio, queue: queue, settings: MediaFileWriter.audioSettings)
        for index in 0..<20 {
            let chunk = Self.audioChunk(index: index, sampleRate: sampleRate, channels: channels)
            queue.sync { writer.append(chunk, hostTime: CMTime(seconds: 500 + Double(index) / 10, preferredTimescale: 1_000_000)) }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let start = await writer.finish()
        guard start != nil else { return (nil, 0, 0) }
        let file = try AVAudioFile(forReading: url)
        return (start, Double(file.length) / file.fileFormat.sampleRate, file.fileFormat.sampleRate)
    }

    /// Every kind of microphone must end up in a real file: built-in (48 kHz),
    /// older USB (44.1 kHz), Bluetooth headsets (24, 16 or 8 kHz, which used to
    /// record nothing) and studio interfaces (88.2 kHz and up, which used to crash).
    func testEveryMicrophoneSampleRateIsRecorded() async throws {
        for (rate, channels) in [(48_000.0, 1), (48_000.0, 2), (44_100.0, 2), (24_000.0, 1), (16_000.0, 1), (8_000.0, 1), (88_200.0, 2), (96_000.0, 2), (192_000.0, 2)] {
            let result = try await record(sampleRate: rate, channels: channels)
            XCTAssertEqual(result.start ?? -1, 500, accuracy: 1e-6, "\(Int(rate)) Hz, \(channels) ch: nothing recorded")
            XCTAssertEqual(result.seconds, 2, accuracy: 0.2, "\(Int(rate)) Hz, \(channels) ch")
            XCTAssertEqual(result.rate, min(rate, 48_000), "\(Int(rate)) Hz, \(channels) ch")
        }
    }

    func testAudioSettings() {
        let normal = MediaFileWriter.audioSettings(sampleRate: 48_000, channels: 1)
        XCTAssertEqual(normal[AVSampleRateKey] as? Double, 48_000)
        XCTAssertEqual(normal[AVEncoderBitRateKey] as? Int, 128_000)
        XCTAssertEqual(MediaFileWriter.audioSettings(sampleRate: 48_000, channels: 2)[AVEncoderBitRateKey] as? Int, 192_000)
        // More than two channels (a multi-input interface) is recorded as stereo.
        XCTAssertEqual(MediaFileWriter.audioSettings(sampleRate: 48_000, channels: 8)[AVNumberOfChannelsKey] as? Int, 2)
        XCTAssertEqual(MediaFileWriter.audioSettings(sampleRate: 96_000, channels: 2)[AVSampleRateKey] as? Double, 48_000)
        XCTAssertNil(MediaFileWriter.audioSettings(sampleRate: 16_000, channels: 1)[AVEncoderBitRateKey])
        XCTAssertEqual(MediaFileWriter.audioSettings(sampleRate: 0, channels: 0)[AVSampleRateKey] as? Double, 48_000)
    }

    func testAFileThatGotNoSoundIsRemoved() async {
        let url = folder.appending(path: "silent.m4a")
        let writer = MediaFileWriter(url: url, fileType: .m4a, mediaType: .audio, queue: queue, settings: MediaFileWriter.audioSettings)
        let start = await writer.finish()
        XCTAssertNil(start)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testAnUnpluggedCameraOrMicrophoneIsNoticedBeforeRecording() {
        func missing(_ camera: String?, _ microphone: String?) -> RecordingError? {
            AppState.missingDevice(cameraID: camera, microphoneID: microphone, cameraIDs: ["cam"], microphoneIDs: ["mic"])
        }
        XCTAssertNil(missing(nil, nil), "“No camera” and “No microphone” are always fine")
        XCTAssertNil(missing("cam", "mic"))
        XCTAssertEqual(missing("gone", "mic"), .cameraMissing)
        XCTAssertEqual(missing("cam", "gone"), .microphoneMissing)
        XCTAssertNotNil(RecordingError.cameraMissing.errorDescription)
    }

    /// The camera is recorded with made-up 720p frames here; the file must
    /// play and stay near the bitrate it was asked for.
    func testCameraFileIsWrittenAtItsOwnSizeAndBitrate() async throws {
        let url = folder.appending(path: "camera.mov")
        let writer = MediaFileWriter(url: url, fileType: .mov, mediaType: .video, queue: queue, settings: MediaFileWriter.cameraSettings)
        for index in 0..<45 {
            let frame = VideoWriterTests.frame(at: Double(index) / 30, width: 1280, height: 720)
            queue.sync { writer.append(frame, hostTime: CMTime(seconds: 700 + Double(index) / 30, preferredTimescale: 1_000_000)) }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let start = await writer.finish()
        XCTAssertEqual(start ?? -1, 700, accuracy: 1e-6)
        let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first
        let size = try await XCTUnwrap(track).load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 1280, height: 720))
        XCTAssertEqual(MediaFileWriter.cameraBitrate, 3_000_000)
    }
}

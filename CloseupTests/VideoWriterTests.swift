import AVFoundation
import XCTest

/// The screen video file, fed with made-up frames instead of a real screen.
final class VideoWriterTests: XCTestCase {
    private let queue = DispatchQueue(label: "closeup.tests.capture")
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appending(path: "closeup-writer-\(UUID().uuidString).mov")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
    }

    /// A grey frame stamped with `seconds` on the host clock, like ScreenCaptureKit's.
    static func frame(at seconds: Double, width: Int = 320, height: Int = 240) -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer!, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer!, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
        return sample!
    }

    private func makeWriter() throws -> VideoWriter {
        try VideoWriter(url: url, width: 320, height: 240, fps: 30, queue: queue)
    }

    private func append(_ times: [Double], to writer: VideoWriter) {
        for time in times {
            let frame = Self.frame(at: time)
            queue.sync { writer.append(frame) }
            // The file is written "live": frames sent faster than the encoder
            // can take them are dropped, as in a real recording. So don't rush.
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    func testWritesAPlayableFileAsLongAsTheRecording() async throws {
        let writer = try makeWriter()
        append((0..<15).map { 1000 + Double($0) / 30 }, to: writer)
        let summary = try await writer.finish(at: 1001)

        XCTAssertEqual(summary.firstFrameTime, 1000, accuracy: 1e-6)
        XCTAssertEqual(summary.endTime, 1001, accuracy: 1e-6)
        XCTAssertEqual(summary.duration, 1, accuracy: 1e-6)
        // Every frame is either written or counted as dropped; none vanish.
        XCTAssertEqual(summary.frameCount + summary.droppedFrameCount, 15)
        XCTAssertGreaterThan(summary.frameCount, 0)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        // The last frame is held until Stop, so the file is as long as the recording.
        XCTAssertEqual(duration, 1, accuracy: 0.05)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
    }

    func testFramesThatGoBackInTimeAreDropped() async throws {
        let writer = try makeWriter()
        append([1000, 1000.1, 1000.05, 1000.2], to: writer)
        let summary = try await writer.finish(at: 1000.5)
        XCTAssertEqual(summary.frameCount + summary.droppedFrameCount, 4)
        XCTAssertGreaterThanOrEqual(summary.droppedFrameCount, 1)
    }

    func testStoppingWithNoFramesReportsAnErrorInsteadOfAnEmptyFile() async throws {
        let writer = try makeWriter()
        do {
            _ = try await writer.finish(at: 1000)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? RecordingError, .noFramesCaptured)
        }
    }

    /// The video file can fail mid-recording (disk full, drive unplugged).
    /// Pressing Stop afterwards used to crash the app.
    func testStoppingAfterTheFileFailedReportsAnErrorInsteadOfCrashing() async throws {
        let writer = try makeWriter()
        append([1000, 1000.1], to: writer)
        writer.breakForTesting()
        append([1000.2], to: writer)  // frames keep arriving after the failure
        do {
            _ = try await writer.finish(at: 1001)
            XCTFail("expected an error")
        } catch {
            // Reaching here without crashing is the point.
        }
    }

    /// A failed file must end the recording at once, not an hour later.
    func testAFailedFileIsReportedOnceWhileRecording() throws {
        let writer = try makeWriter()
        var failures = 0
        writer.onFailure = { _ in failures += 1 }
        append([1000, 1000.1], to: writer)
        XCTAssertEqual(failures, 0)
        writer.breakForTesting()
        append([1000.2, 1000.3, 1000.4], to: writer)
        XCTAssertEqual(failures, 1)
    }

    @MainActor
    func testWarningsForARecordingSavedWithoutSomething() {
        func warnings(_ cameraWanted: Bool, _ camera: Bool, _ microphoneWanted: Bool, _ microphone: Bool) -> [String] {
            RecordingSession.warnings(
                cameraWanted: cameraWanted, cameraRecorded: camera, microphoneWanted: microphoneWanted, microphoneRecorded: microphone)
        }
        XCTAssertEqual(warnings(false, false, false, false), [], "nothing asked for, nothing missing")
        XCTAssertEqual(warnings(true, true, true, true), [])
        XCTAssertEqual(warnings(true, false, true, true), ["The camera wasn't recorded."])
        XCTAssertEqual(warnings(true, false, true, false).count, 2)
    }

    func testPartlySavedMessageSaysWhereTheFilesAre() {
        let error = RecordingError.partlySaved(reason: "No frames were captured.", folder: "Recording 2026-11-01 at 14.03.22")
        XCTAssertEqual(
            error.errorDescription,
            "No frames were captured. What was captured is in “Recording 2026-11-01 at 14.03.22” in your Movies/Closeup folder.")
    }
}

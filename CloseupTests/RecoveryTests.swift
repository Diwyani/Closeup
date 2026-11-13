import AVFoundation
import XCTest

/// Rescuing a recording that never reached Stop (crash, force quit, power cut).
@MainActor
final class RecoveryTests: XCTestCase {
    private let videoQueue = DispatchQueue(label: "closeup.tests.recovery.video")
    private let audioQueue = DispatchQueue(label: "closeup.tests.recovery.audio")
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "closeup-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func newProject(_ name: String) throws -> RecordingProject {
        let project = RecordingProject(folder: folder.appending(path: name, directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: project.folder, withIntermediateDirectories: true)
        return project
    }

    private func inProgress() -> RecordingRecovery.InProgress {
        .init(
            metadata: RecordingMetadata(
                createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                source: .init(kind: .display, name: "Test display", displayID: 1, windowID: nil),
                captureFrame: Rect(CGRect(x: 0, y: 0, width: 320, height: 200)),
                scale: 2, videoWidth: 640, videoHeight: 400, fps: 60,
                duration: 0, frameCount: 0, droppedFrameCount: 0, displays: []),
            cameraName: nil, microphoneName: "Test microphone")
    }

    private func rawEvents() -> [CursorLogger.RawEvent] {
        [
            .init(hostTime: 999.5, position: CGPoint(x: 10, y: 10), type: .move),   // before the video
            .init(hostTime: 1000.2, position: CGPoint(x: 100, y: 50), type: .move),
            .init(hostTime: 1000.4, position: CGPoint(x: 100, y: 50), type: .leftDown),
            .init(hostTime: 1000.45, position: CGPoint(x: 100, y: 50), type: .shape, shape: 1),
            .init(hostTime: 5000, position: CGPoint(x: 0, y: 0), type: .move),      // long after the video
        ]
    }

    /// Records `seconds` of made-up screen and microphone into `project`, the
    /// way a real recording does, and returns the writers still open.
    private func record(into project: RecordingProject, seconds: Double) throws -> (VideoWriter, MediaFileWriter) {
        RecordingRecovery.begin(project, inProgress())
        let journal = try XCTUnwrap(CursorJournal(url: project.cursorJournalURL))
        journal.append(rawEvents()[...])
        journal.close()

        let video = try VideoWriter(url: project.videoURL, width: 640, height: 400, fps: 30, queue: videoQueue)
        let microphone = MediaFileWriter(
            url: project.microphoneURL, fileType: .m4a, mediaType: .audio, queue: audioQueue,
            settings: MediaFileWriter.audioSettings)
        // The microphone starts a quarter second before the screen, as it does for real.
        for step in 0..<Int(seconds * 30) {
            let time = 1000 + Double(step) / 30
            let frame = VideoWriterTests.frame(at: time, width: 640, height: 400)
            videoQueue.sync { video.append(frame) }
            if step % 3 == 0 {
                let chunk = MediaFileWriterTests.audioChunk(index: step / 3, sampleRate: 48_000, channels: 1)
                audioQueue.sync {
                    microphone.append(chunk, hostTime: CMTime(seconds: 999.75 + Double(step) / 30, preferredTimescale: 1_000_000))
                }
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return (video, microphone)
    }

    /// The heart of it: copy the folder while the files are still being
    /// written (what a crash leaves behind), then recover the copy.
    func testARecordingCutOffMidWayIsRecoveredAndCanBeExported() async throws {
        let live = try newProject("live")
        let (video, microphone) = try record(into: live, seconds: 4)

        let crashed = RecordingProject(folder: folder.appending(path: "crashed", directoryHint: .isDirectory))
        try FileManager.default.copyItem(at: live.folder, to: crashed.folder)
        _ = try await video.finish(at: 1004)   // tidy up the originals
        _ = await microphone.finish()

        XCTAssertTrue(RecordingRecovery.isInterrupted(crashed))
        let recovered = await RecordingRecovery.recover(crashed)
        XCTAssertTrue(recovered)

        let metadata = try crashed.loadMetadata()
        // At least the first pieces survived (the last second or so may not have).
        XCTAssertGreaterThan(metadata.duration, 1)
        XCTAssertLessThanOrEqual(metadata.duration, 4.1)
        XCTAssertEqual(metadata.source.name, "Test display")
        XCTAssertEqual(metadata.videoWidth, 640)
        let mic = try XCTUnwrap(metadata.microphone, "the microphone file should be rescued too")
        XCTAssertEqual(mic.offset, -0.25, accuracy: 0.001)
        XCTAssertEqual(mic.deviceName, "Test microphone")
        XCTAssertNil(metadata.camera)

        let events = try crashed.loadCursorLog().events
        XCTAssertEqual(events.first, CursorEvent(t: 0, x: 10, y: 10, type: .move), "position before the video becomes the start")
        XCTAssertTrue(events.contains { $0.isClick && abs($0.t - 0.4) < 0.001 })
        XCTAssertFalse(events.contains { $0.t > metadata.duration })

        XCTAssertFalse(RecordingRecovery.isInterrupted(crashed))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: crashed.folder.path)
            .filter { $0.contains("in-progress") || $0.hasSuffix(".start") }
        XCTAssertEqual(leftovers, [])

        // And it opens in the editor and exports like any other recording.
        let model = try await ProjectEditorModel.load(crashed)
        let url = try await FixtureProject.export(model)
        let exported = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(exported, metadata.duration, accuracy: 0.15)
    }

    /// A normal Stop must still give a file the editor and exporter accept,
    /// now that files are written in pieces.
    func testANormallyFinishedRecordingStillOpensAndExports() async throws {
        let project = try newProject("finished")
        let (video, microphone) = try record(into: project, seconds: 2)
        let summary = try await video.finish(at: 1002)
        let microphoneStart = await microphone.finish()
        XCTAssertEqual(microphoneStart ?? 0, 999.75, accuracy: 0.001)

        var metadata = inProgress().metadata
        metadata.duration = summary.duration
        metadata.microphone = .init(file: "microphone.m4a", offset: -0.25, deviceName: nil)
        let cursor = CursorLog(
            scale: 2, width: 320, height: 200,
            events: CursorLog.videoTimeline(rawEvents(), videoStart: summary.firstFrameTime, videoEnd: summary.endTime))
        try project.write(metadata: metadata, cursor: cursor)
        project.removeInProgressFiles()

        let model = try await ProjectEditorModel.load(project)
        XCTAssertTrue(model.hasMicrophone)
        let url = try await FixtureProject.export(model)
        let asset = AVURLAsset(url: url)
        let exported = try await asset.load(.duration).seconds
        XCTAssertEqual(exported, 2, accuracy: 0.15)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
    }

    func testFinishedAndEmptyFoldersAreLeftAlone() async throws {
        // A finished recording: nothing to recover.
        let finished = try FixtureProject.make()
        defer { finished.delete() }
        let before = try Data(contentsOf: finished.metadataURL)
        let recoveredFinished = await RecordingRecovery.recover(finished)
        XCTAssertFalse(recoveredFinished)
        XCTAssertEqual(try Data(contentsOf: finished.metadataURL), before)

        // Interrupted before any video was written: can't be rescued, and isn't touched.
        let empty = try newProject("empty")
        RecordingRecovery.begin(empty, inProgress())
        let recoveredEmpty = await RecordingRecovery.recover(empty)
        XCTAssertFalse(recoveredEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: empty.inProgressURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.metadataURL.path))
    }

    func testRecoverAllFindsOnlyInterruptedRecordings() async throws {
        let live = try newProject("live")
        let (video, microphone) = try record(into: live, seconds: 3)
        let library = folder.appending(path: "library", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: live.folder, to: library.appending(path: "Recording A"))
        _ = try await video.finish(at: 1003)
        _ = await microphone.finish()
        try FileManager.default.createDirectory(at: library.appending(path: "Some other folder"), withIntermediateDirectories: true)

        let first = await RecordingRecovery.recoverAll(in: library)
        XCTAssertEqual(first, 1)
        let second = await RecordingRecovery.recoverAll(in: library)
        XCTAssertEqual(second, 0, "already recovered")
    }

    func testCursorJournalSurvivesBeingCutOffMidLine() throws {
        let url = folder.appending(path: "cursor.jsonl")
        let journal = try XCTUnwrap(CursorJournal(url: url))
        journal.append(rawEvents()[0..<2])
        journal.append(rawEvents()[2..<4])
        journal.close()
        XCTAssertEqual(CursorJournal.read(url).count, 4)
        XCTAssertEqual(CursorJournal.read(url)[3].shape, 1)

        // A crash in the middle of writing a line.
        var data = try Data(contentsOf: url)
        data.append(Data(#"{"hostTime":1001,"posi"#.utf8))
        try data.write(to: url)
        XCTAssertEqual(CursorJournal.read(url).count, 4)
        XCTAssertTrue(CursorJournal.read(folder.appending(path: "missing.jsonl")).isEmpty)
    }

    func testStartTimesAreKeptExactly() {
        let file = folder.appending(path: "screen.mov")
        XCTAssertNil(RecordingRecovery.startTime(of: file))
        RecordingRecovery.noteStart(of: file, hostTime: 123_456.789_012_345)
        XCTAssertEqual(RecordingRecovery.startTime(of: file), 123_456.789_012_345)
    }
}

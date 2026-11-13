import XCTest

/// Saving and loading a recording's folder.
final class ProjectFilesTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "closeup-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func sampleMetadata() -> RecordingMetadata {
        RecordingMetadata(
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            source: .init(kind: .window, name: "Safari – Apple", displayID: nil, windowID: 42),
            captureFrame: Rect(CGRect(x: 10, y: 20, width: 1440, height: 900)),
            scale: 2, videoWidth: 2880, videoHeight: 1800, fps: 60,
            duration: 12.5, frameCount: 700, droppedFrameCount: 3,
            displays: [.init(id: 1, frame: Rect(CGRect(x: 0, y: 0, width: 1440, height: 900)), scale: 2, isPrimary: true)],
            camera: .init(file: "camera.mov", offset: -1.25, deviceName: "FaceTime HD Camera"),
            microphone: nil,
            systemAudio: .init(file: "system-audio.m4a", offset: 0.02, deviceName: nil))
    }

    func testFileNamesInsideARecording() {
        let project = RecordingProject(folder: folder)
        XCTAssertEqual(project.videoURL.lastPathComponent, "screen.mov")
        XCTAssertEqual(project.cursorURL.lastPathComponent, "cursor.json")
        XCTAssertEqual(project.metadataURL.lastPathComponent, "project.json")
        XCTAssertEqual(project.styleURL.lastPathComponent, "style.json")
        XCTAssertEqual(project.cameraURL.lastPathComponent, "camera.mov")
        XCTAssertEqual(project.microphoneURL.lastPathComponent, "microphone.m4a")
        XCTAssertEqual(project.systemAudioURL.lastPathComponent, "system-audio.m4a")
        XCTAssertEqual(project.exportURL(for: "1080p").lastPathComponent, "Export 1080p.mp4")
    }

    func testMetadataAndCursorLogSurviveSavingAndLoading() throws {
        let project = RecordingProject(folder: folder)
        let metadata = sampleMetadata()
        let cursor = CursorLog(scale: 2, width: 1440, height: 900, events: [CursorEvent(t: 0.5, x: 1, y: 2, type: .leftDown)])
        try project.write(metadata: metadata, cursor: cursor)

        let loaded = try project.loadMetadata()
        XCTAssertEqual(loaded.createdAt, metadata.createdAt)
        XCTAssertEqual(loaded.source.name, "Safari – Apple")
        XCTAssertEqual(loaded.source.windowID, 42)
        XCTAssertEqual(loaded.captureFrame, metadata.captureFrame)
        XCTAssertEqual(loaded.duration, 12.5)
        XCTAssertEqual(loaded.frameCount, 700)
        XCTAssertEqual(loaded.camera?.offset, -1.25)
        XCTAssertNil(loaded.microphone)
        XCTAssertEqual(loaded.systemAudio?.file, "system-audio.m4a")
        XCTAssertEqual(try project.loadCursorLog().events, cursor.events)
    }

    /// A project.json exactly as version 1 of the app wrote it. If this stops
    /// loading, old recordings disappear from the sidebar.
    func testReadsAProjectFileWrittenByVersion1() throws {
        let json = """
        {"captureFrame":{"height":900,"width":1440,"x":0,"y":0},"createdAt":"2026-11-01T14:03:22Z",
         "displays":[{"frame":{"height":900,"width":1440,"x":0,"y":0},"id":1,"isPrimary":true,"scale":2}],
         "droppedFrameCount":0,"duration":8.2,"fps":60,"frameCount":412,"scale":2,
         "source":{"displayID":1,"kind":"display","name":"Built-in Retina Display"},
         "version":1,"videoHeight":1800,"videoWidth":2880}
        """
        let project = RecordingProject(folder: folder)
        try Data(json.utf8).write(to: project.metadataURL)
        let metadata = try project.loadMetadata()
        XCTAssertEqual(metadata.source.kind, .display)
        XCTAssertEqual(metadata.duration, 8.2)
        XCTAssertNil(metadata.camera)
    }

    func testLoadingAMissingOrBrokenFileThrowsInsteadOfCrashing() throws {
        let project = RecordingProject(folder: folder)
        XCTAssertThrowsError(try project.loadMetadata())
        try Data("not json".utf8).write(to: project.metadataURL)
        XCTAssertThrowsError(try project.loadMetadata())
        XCTAssertThrowsError(try project.loadCursorLog())
    }

    func testRenamingMovesTheFolderAndCleansTheName() throws {
        let project = RecordingProject(folder: folder)
        try project.write(metadata: sampleMetadata(), cursor: CursorLog(scale: 2, width: 1, height: 1, events: []))
        let renamed = try project.renamed(to: "  Demo: part 1/2  ")
        defer { renamed.delete() }
        XCTAssertEqual(renamed.name, "Demo- part 1-2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.metadataURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testRenamingRefusesBadOrTakenNames() throws {
        let project = RecordingProject(folder: folder)
        XCTAssertThrowsError(try project.renamed(to: "   "))
        XCTAssertThrowsError(try project.renamed(to: ".hidden"))
        let other = folder.deletingLastPathComponent().appending(path: "closeup-taken-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        XCTAssertThrowsError(try project.renamed(to: other.lastPathComponent))
        // Same name: nothing to do.
        XCTAssertEqual(try project.renamed(to: project.name), project)
    }

    func testDisplayNameDropsTheRecordingPrefix() {
        let project = RecordingProject(folder: URL(fileURLWithPath: "/tmp/Recording 2026-11-01 at 14.03.22"))
        XCTAssertEqual(project.displayName, "2026-11-01 at 14.03.22")
    }
}

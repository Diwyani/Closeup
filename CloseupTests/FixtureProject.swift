import AVFoundation
import XCTest

/// The tiny sample recording in CloseupTests/Fixtures (made by
/// scripts/make-fixture.swift), copied into a throwaway folder so tests can
/// export from it and change it freely.
enum FixtureProject {
    /// CloseupTests/Fixtures in the source tree. Read straight from disk, so
    /// new reference pictures can be saved next to the old ones.
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")

    static func make() throws -> RecordingProject {
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "closeup-fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let project = RecordingProject(folder: destination)
        for (name, url) in [
            ("fixture-screen.mov", project.videoURL),
            ("fixture-cursor.json", project.cursorURL),
            ("fixture-project.json", project.metadataURL),
        ] {
            try FileManager.default.copyItem(at: folder.appending(path: name), to: url)
        }
        return project
    }

    /// Exports through the editor, exactly as pressing Export does.
    @MainActor
    static func export(_ model: ProjectEditorModel, resolution: ExportResolution = .hd720) async throws -> URL {
        model.resolution = resolution
        model.export()
        while model.exportProgress != nil { try await Task.sleep(for: .milliseconds(50)) }
        if let error = model.exportError { throw NSError(domain: "Export", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
        return try XCTUnwrap(model.exportedURL)
    }
}

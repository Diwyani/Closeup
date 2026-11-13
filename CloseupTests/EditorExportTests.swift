import AVFoundation
import XCTest

/// The editor and the exporter working together, on the sample recording.
/// Each test here guards a bug that was found and fixed.
@MainActor
final class EditorExportTests: XCTestCase {
    private var project: RecordingProject!

    override func setUpWithError() throws {
        project = try FixtureProject.make()
    }

    override func tearDown() {
        project.delete()
    }

    private func length(of url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    func testExportWithoutEditsIsTheWholeRecording() async throws {
        let model = try await ProjectEditorModel.load(project)
        let url = try await FixtureProject.export(model)
        let seconds = try await length(of: url)
        XCTAssertEqual(seconds, 2, accuracy: 0.1)
    }

    /// Trimming used to be ignored by Export if it was the last thing you changed.
    func testExportUsesATrimMadeJustBeforeExporting() async throws {
        let model = try await ProjectEditorModel.load(project)
        model.setTrimStart(0.5)
        model.setTrimEnd(1.5)
        let url = try await FixtureProject.export(model)
        let seconds = try await length(of: url)
        XCTAssertEqual(seconds, 1, accuracy: 0.1)
    }

    func testExportAppliesCutsAndSpeedUps() async throws {
        let model = try await ProjectEditorModel.load(project)
        model.style.timeEdits = [TimeEdit(kind: .cut, start: 0.5, end: 1.0)]
        let url = try await FixtureProject.export(model)
        let seconds = try await length(of: url)
        XCTAssertEqual(seconds, 1.5, accuracy: 0.1)
    }
}

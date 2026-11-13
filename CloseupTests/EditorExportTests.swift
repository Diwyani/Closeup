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

    /// Undo often changes several settings in one go. Turning zoom off and
    /// cuts on together used to leave the old zooms in the preview and export.
    func testOneChangeToSeveralSettingsAppliesAllOfThem() async throws {
        let model = try await ProjectEditorModel.load(project)
        XCTAssertFalse(model.zoomSegments.isEmpty, "the sample has a click, so it starts with a zoom")
        var changed = model.style
        changed.autoZoom = false
        changed.cutsSilence = true
        changed.trimStart = 0.25
        model.style = changed
        XCTAssertTrue(model.zoomSegments.isEmpty)
        XCTAssertEqual(model.trimStart, 0.25)

        model.undo()
        XCTAssertFalse(model.zoomSegments.isEmpty)
        XCTAssertEqual(model.trimStart, 0)
        XCTAssertTrue(model.canRedo)
    }

    /// After an export, automatic cuts used to become impossible to delete.
    func testAutomaticCutsCanStillBeDeletedAfterExporting() async throws {
        let model = try await ProjectEditorModel.load(project)
        var changed = model.style
        changed.cutsSilence = true
        changed.silenceLength = 0.5  // the sample's quiet second half is now a cut
        model.style = changed
        XCTAssertEqual(model.automaticEditCount(.cut), 1)

        _ = try await FixtureProject.export(model)
        XCTAssertEqual(model.automaticEditCount(.cut), 1)

        model.selectedID = try XCTUnwrap(model.timeEdits.first).id
        model.deleteSelected()
        XCTAssertTrue(model.timeEdits.isEmpty)
        XCTAssertEqual(model.style.dismissedEdits.count, 1, "remembered, so it doesn't come back")
    }

    func testAutomaticCutShortensTheExport() async throws {
        let model = try await ProjectEditorModel.load(project)
        var changed = model.style
        changed.cutsSilence = true
        changed.silenceLength = 0.5
        model.style = changed
        let cut = try XCTUnwrap(model.timeEdits.first)
        let url = try await FixtureProject.export(model)
        let seconds = try await length(of: url)
        XCTAssertEqual(seconds, 2 - (cut.end - cut.start), accuracy: 0.1)
    }

    func testUndoAndRedoRestoreSettings() async throws {
        let model = try await ProjectEditorModel.load(project)
        XCTAssertFalse(model.canUndo)
        model.style.padding = 20
        XCTAssertTrue(model.canUndo)
        model.undo()
        XCTAssertEqual(model.style.padding, 80)
        model.redo()
        XCTAssertEqual(model.style.padding, 20)
    }

    func testSettingsAreSavedToStyleFile() async throws {
        let model = try await ProjectEditorModel.load(project)
        model.style.padding = 33
        try await Task.sleep(for: .milliseconds(900))  // saved shortly after the last change
        XCTAssertEqual(try ExportStyle.load(from: project.styleURL).padding, 33)
    }
}

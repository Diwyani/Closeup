import Foundation

/// One recording on disk. Each recording is a plain folder so it's easy to
/// inspect in Finder while we build the app:
///
///     ~/Movies/Closeup/Recording 2026-11-01 at 14.03.22/
///         screen.mov     raw capture, system cursor hidden
///         cursor.json    CursorLog: every move/click, synced to the video
///         project.json   RecordingMetadata: source, sizes, fps, duration
///         cursors/       PNGs of non-arrow cursor shapes (I-beam, hand, tools)
///         camera.mov, microphone.m4a, system-audio.m4a   (when recorded)
///         style.json     look settings from the editor (once edited)
///         Export 1080p.mp4 / Export 4K.mp4
///
/// Everything "pretty" (cursor, zoom, background) is computed from these
/// files at export time, so a recording stays fully editable.
struct RecordingProject: Identifiable, Hashable {
    let folder: URL

    var id: URL { folder }
    var name: String { folder.lastPathComponent }

    var videoURL: URL { folder.appending(path: "screen.mov") }
    var cursorURL: URL { folder.appending(path: "cursor.json") }
    var metadataURL: URL { folder.appending(path: "project.json") }
    var styleURL: URL { folder.appending(path: "style.json") }
    var cameraURL: URL { folder.appending(path: "camera.mov") }
    var microphoneURL: URL { folder.appending(path: "microphone.m4a") }
    /// Noise-reduced, level copy of the microphone (made on request).
    var cleanMicrophoneURL: URL { folder.appending(path: "microphone-clean.m4a") }
    var systemAudioURL: URL { folder.appending(path: "system-audio.m4a") }
    /// PNGs of the cursor shapes listed in cursor.json.
    var cursorsFolder: URL { folder.appending(path: "cursors", directoryHint: .isDirectory) }

    func exportURL(for label: String) -> URL {
        folder.appending(path: "Export \(label).mp4")
    }

    /// "2026-11-01 at 21.32.44" for the sidebar.
    var displayName: String {
        name.replacingOccurrences(of: "Recording ", with: "")
    }

    /// ~/Movies/Closeup
    static var libraryFolder: URL {
        URL.moviesDirectory.appending(path: "Closeup", directoryHint: .isDirectory)
    }

    /// The app used to be called QueenStudio; move its recordings over once.
    static func moveOldLibrary() {
        let old = URL.moviesDirectory.appending(path: "QueenStudio", directoryHint: .isDirectory)
        let files = FileManager.default
        guard files.fileExists(atPath: old.path), !files.fileExists(atPath: libraryFolder.path) else { return }
        try? files.moveItem(at: old, to: libraryFolder)
    }

    /// Makes a new, empty project folder named after the current time.
    static func create(at date: Date = .now) throws -> RecordingProject {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let folder = libraryFolder.appending(
            path: "Recording \(formatter.string(from: date))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return RecordingProject(folder: folder)
    }

    /// All projects in the library, newest first. (Used by the Phase 2 project list.)
    static func all() -> [RecordingProject] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: libraryFolder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return folders
            .map(RecordingProject.init(folder:))
            .filter { FileManager.default.fileExists(atPath: $0.metadataURL.path) }
            .sorted { $0.name > $1.name }
    }

    // MARK: Reading and writing

    func write(metadata: RecordingMetadata, cursor: CursorLog) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // The cursor log can hold tens of thousands of events, so keep it compact.
        try encoder.encode(cursor).write(to: cursorURL, options: .atomic)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
    }

    func loadMetadata() throws -> RecordingMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecordingMetadata.self, from: Data(contentsOf: metadataURL))
    }

    func loadCursorLog() throws -> CursorLog {
        try JSONDecoder().decode(CursorLog.self, from: Data(contentsOf: cursorURL))
    }

    /// Removes the folder, e.g. when a recording failed before any frame was saved.
    func delete() {
        try? FileManager.default.removeItem(at: folder)
    }
}

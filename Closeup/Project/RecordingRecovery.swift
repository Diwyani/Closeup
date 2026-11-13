import AVFoundation
import os

/// Rescues a recording that never reached Stop: the app crashed or was
/// force-quit, the Mac lost power, or a file failed part-way.
///
/// While recording, everything needed to finish the job later is kept on disk:
///
///     screen.mov, camera.mov, *.m4a    written in one-second pieces, so they
///                                      play up to the last piece
///     <file>.start                     when each file began (host clock)
///     recording-in-progress.json       what was being recorded
///     cursor-in-progress.jsonl         the cursor log so far, one event per line
///     cursor-shapes-in-progress.json   cursor shapes seen so far
///
/// A normal Stop writes project.json and cursor.json and removes these. A
/// folder that still has them (and no project.json) was interrupted, and
/// `recover` finishes it from what's there.
enum RecordingRecovery {
    /// What a normal Stop would have put in project.json, minus what's only
    /// known at the end (duration, frame counts, the extra files).
    struct InProgress: Codable {
        var metadata: RecordingMetadata
        var cameraName: String?
        var microphoneName: String?
    }

    /// The video must be at least this long to be worth keeping.
    static let shortestWorthKeeping = 0.5

    // MARK: While recording

    static func begin(_ project: RecordingProject, _ inProgress: InProgress) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(inProgress).write(to: project.inProgressURL, options: .atomic)
        } catch {
            Logger.recording.error("Couldn't write the recovery file: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Notes when a media file's first sample arrived, next to the file.
    static func noteStart(of file: URL, hostTime: Double) {
        try? Data("\(hostTime)".utf8).write(to: RecordingProject.startTimeURL(for: file), options: .atomic)
    }

    static func startTime(of file: URL) -> Double? {
        (try? String(contentsOf: RecordingProject.startTimeURL(for: file), encoding: .utf8))
            .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    // MARK: Afterwards

    /// Finishes every interrupted recording in the library. Returns how many
    /// were rescued. Call at launch, never while recording.
    static func recoverAll(in library: URL = RecordingProject.libraryFolder) async -> Int {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: library, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        var rescued = 0
        for folder in folders where await recover(RecordingProject(folder: folder)) { rescued += 1 }
        return rescued
    }

    /// Whether this folder holds an interrupted recording.
    static func isInterrupted(_ project: RecordingProject) -> Bool {
        FileManager.default.fileExists(atPath: project.inProgressURL.path)
            && !FileManager.default.fileExists(atPath: project.metadataURL.path)
    }

    /// Writes project.json and cursor.json for an interrupted recording from
    /// what is on disk. False (and nothing is changed) if there isn't a
    /// usable screen video.
    @discardableResult
    static func recover(_ project: RecordingProject) async -> Bool {
        guard isInterrupted(project) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard
            let data = try? Data(contentsOf: project.inProgressURL),
            let inProgress = try? decoder.decode(InProgress.self, from: data),
            let videoStart = startTime(of: project.videoURL),
            let videoLength = await playableLength(of: project.videoURL, .video),
            videoLength >= shortestWorthKeeping
        else { return false }

        var metadata = inProgress.metadata
        metadata.duration = videoLength
        metadata.camera = await track(project.cameraURL, .video, videoStart: videoStart, device: inProgress.cameraName)
        metadata.microphone = await track(project.microphoneURL, .audio, videoStart: videoStart, device: inProgress.microphoneName)
        metadata.systemAudio = await track(project.systemAudioURL, .audio, videoStart: videoStart, device: nil)

        let shapes = (try? JSONDecoder().decode([CursorShape].self, from: Data(contentsOf: project.cursorShapesJournalURL))) ?? []
        let cursor = CursorLog(
            scale: metadata.scale,
            width: metadata.captureFrame.width,
            height: metadata.captureFrame.height,
            shapes: shapes.isEmpty ? nil : shapes,
            events: CursorLog.videoTimeline(
                CursorJournal.read(project.cursorJournalURL), videoStart: videoStart, videoEnd: videoStart + videoLength))
        do {
            try project.write(metadata: metadata, cursor: cursor)
        } catch {
            Logger.recording.error("Couldn't finish \(project.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
        project.removeInProgressFiles()
        Logger.recording.notice("Recovered \(project.name, privacy: .public): \(videoLength) s")
        return true
    }

    /// How much of a file plays, or nil if it can't be opened at all.
    private static func playableLength(of url: URL, _ mediaType: AVMediaType) async -> Double? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        guard
            let track = try? await asset.loadTracks(withMediaType: mediaType).first,
            let range = try? await track.load(.timeRange),
            range.duration.seconds.isFinite, range.duration.seconds > 0
        else { return nil }
        return range.end.seconds
    }

    private static func track(
        _ url: URL, _ mediaType: AVMediaType, videoStart: Double, device: String?
    ) async -> RecordingMetadata.MediaTrack? {
        guard let start = startTime(of: url), await playableLength(of: url, mediaType) != nil else { return nil }
        return .init(file: url.lastPathComponent, offset: start - videoStart, deviceName: device)
    }
}

/// The cursor log as it grows during a recording: one JSON event per line,
/// only ever added to, so a crash loses at most the last couple of seconds.
final class CursorJournal {
    private let handle: FileHandle
    private let encoder = JSONEncoder()

    init?(url: URL) {
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url)
        else { return nil }
        self.handle = handle
    }

    func append(_ events: ArraySlice<CursorLogger.RawEvent>) {
        var lines = Data()
        for event in events {
            guard let line = try? encoder.encode(event) else { continue }
            lines.append(line)
            lines.append(0x0A)
        }
        guard !lines.isEmpty else { return }
        try? handle.write(contentsOf: lines)
    }

    func close() {
        try? handle.close()
    }

    /// Every complete line. A last line cut off mid-write is skipped.
    static func read(_ url: URL) -> [CursorLogger.RawEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(CursorLogger.RawEvent.self, from: $0) }
    }
}

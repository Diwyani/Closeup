import AVFoundation
import Observation

/// State for editing one recording: its style, the live preview and exporting.
///
/// Two timelines are in play. Recording time is what the timeline view,
/// cursor log and zooms use. Output time is the edited video after cuts and
/// speed-ups, which is what the player and exporter run on.
/// `timeMap` converts between them.
@MainActor
@Observable
final class ProjectEditorModel {
    /// The preview renders at 1080p in the chosen shape; the compositor scales
    /// everything, so 4K exports look the same.
    var previewSize: CGSize { ExportResolution.hd1080.size(for: style.aspect) }

    let project: RecordingProject
    let metadata: RecordingMetadata
    let player: AVPlayer

    var style: ExportStyle {
        didSet { styleDidChange(from: oldValue) }
    }
    var resolution = ExportResolution.hd1080
    /// The zooms in use: edited ones if any, otherwise the automatic ones.
    private(set) var zoomSegments: [ZoomSegment] = []
    /// Cuts and speed-ups in use: edited ones if any, otherwise automatic.
    private(set) var timeEdits: [TimeEdit] = []
    /// The selected zoom or edit on the timeline.
    var selectedID: UUID?
    /// Playhead position, in recording time.
    private(set) var currentTime = 0.0
    /// Length of the final video (after trim, cuts and speed-ups).
    private(set) var outputLength = 0.0

    private(set) var isGeneratingCaptions = false
    private(set) var captionError: String?
    private(set) var isCleaningAudio = false
    private(set) var audioError: String?

    /// 0…1 while exporting, nil otherwise.
    private(set) var exportProgress: Double?
    private(set) var exportedURL: URL?
    private(set) var exportError: String?

    @ObservationIgnored private let cursorLog: CursorLog
    /// When you're talking (from the mic), so automatic edits never touch it.
    @ObservationIgnored private var speechRanges: [ClosedRange<Double>] = []
    @ObservationIgnored private let sprites: CursorSprites
    @ObservationIgnored private var cursorTrack: CursorTrack
    @ObservationIgnored private var cameraTrack: CameraTrack?
    @ObservationIgnored private let liveCompositor: LiveCompositor
    @ObservationIgnored private var sources: ProjectSources
    @ObservationIgnored private var composition: ProjectComposition
    /// Matches the composition currently in the player.
    @ObservationIgnored private var timeMap: TimeMap
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?

    var duration: Double { metadata.duration }
    var hasCamera: Bool { sources.camera != nil }
    var hasMicrophone: Bool { sources.microphone != nil }
    var hasSystemAudio: Bool { sources.systemAudio != nil }

    static func load(_ project: RecordingProject) async throws -> ProjectEditorModel {
        let metadata = try project.loadMetadata()
        let cursorLog = try project.loadCursorLog()
        let style = (try? ExportStyle.load(from: project.styleURL)) ?? ExportStyle()
        let sprites = CursorSprites.load(cursorLog.shapes ?? [], from: project.cursorsFolder)
        let sources = try await CompositionBuilder.loadSources(
            project: project, metadata: metadata, cleanMicrophone: style.cleansAudio)

        let model = try ProjectEditorModel(
            project: project, metadata: metadata, style: style,
            cursorLog: cursorLog, sprites: sprites, sources: sources)
        model.rebuildTracks()
        model.rebuildTimeline()
        model.observePlayhead()
        model.detectSpeech()
        return model
    }

    private init(
        project: RecordingProject, metadata: RecordingMetadata, style: ExportStyle,
        cursorLog: CursorLog, sprites: CursorSprites, sources: ProjectSources
    ) throws {
        self.project = project
        self.metadata = metadata
        self.player = AVPlayer()
        self.style = style
        self.cursorLog = cursorLog
        self.sprites = sprites
        self.sources = sources
        self.cursorTrack = CursorTrack(log: cursorLog, duration: metadata.duration, smoothing: style.cursorSmoothing)
        let live = LiveCompositor(FrameCompositor(style: style, sourceScale: cursorLog.scale))
        self.liveCompositor = live
        // Placeholder until rebuildTimeline() runs right after init.
        self.timeMap = TimeMap(edits: [], duration: metadata.duration)
        self.composition = try CompositionBuilder.make(
            sources: sources, edits: [], canvas: ExportResolution.hd1080.size(for: style.aspect),
            fps: metadata.fps, compositor: live)
    }

    // MARK: Style

    private func styleDidChange(from old: ExportStyle) {
        defer { scheduleSave() }
        if style.cleansAudio != old.cleansAudio {
            Task { await applyAudioCleanup() }
        }
        if style.timeEdits != old.timeEdits || style.speedUpIdle != old.speedUpIdle || style.idleSpeed != old.idleSpeed
            || style.cutsSilence != old.cutsSilence || style.silenceLength != old.silenceLength {
            timeEdits = currentTimeEdits()
            scheduleTimelineRebuild()
            return
        }
        if style.aspect != old.aspect {
            player.currentItem?.videoComposition = composition.videoComposition(renderSize: previewSize)
        }
        if style.trimStart != old.trimStart || style.trimEnd != old.trimEnd {
            applyTrim()
            return
        }
        if style.microphoneVolume != old.microphoneVolume || style.systemVolume != old.systemVolume {
            player.currentItem?.audioMix = composition.audioMix(
                microphoneVolume: style.microphoneVolume, systemVolume: style.systemVolume)
            return
        }
        if style.cursorSmoothing != old.cursorSmoothing
            || style.autoZoom != old.autoZoom
            || style.zoomLevel != old.zoomLevel
            || style.zoomOnTyping != old.zoomOnTyping
            || style.zoomSpeed != old.zoomSpeed
            || style.zoomSegments != old.zoomSegments {
            rebuildTracks()
        } else {
            updateCompositor()
        }
    }

    /// Recomputes the cursor path, the zoom segments and the camera.
    private func rebuildTracks() {
        cursorTrack = CursorTrack(log: cursorLog, duration: duration, smoothing: style.cursorSmoothing)
        if style.autoZoom {
            let activities = ZoomPlanner.activities(from: cursorLog, duration: duration, includeTyping: style.zoomOnTyping)
            zoomSegments = style.zoomSegments
                ?? ZoomPlanner.segments(for: activities, duration: duration, scale: style.zoomLevel)
            cameraTrack = CameraTrack(
                segments: zoomSegments, activities: activities, cursor: cursorTrack,
                screenSize: CGSize(width: cursorLog.width, height: cursorLog.height),
                duration: duration, speed: style.zoomSpeed)
        } else {
            zoomSegments = []
            cameraTrack = nil
        }
        updateCompositor()
    }

    private func updateCompositor() {
        liveCompositor.current = FrameCompositor(
            style: style, cursor: cursorTrack, camera: cameraTrack, sprites: sprites,
            sourceScale: cursorLog.scale, timeMap: timeMap)

        // A paused player doesn't redraw by itself; seeking in place makes it
        // render the current frame again with the new settings.
        if player.rate == 0 {
            player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    // MARK: Timeline: cuts & speed-ups

    private func currentTimeEdits() -> [TimeEdit] {
        style.timeEdits ?? AutoEditPlanner.edits(
            from: cursorLog, speech: speechRanges, duration: duration,
            speedUp: style.speedUpIdle, speed: style.idleSpeed,
            cutSilence: style.cutsSilence, silenceLength: style.silenceLength)
    }

    /// Rebuilding swaps the player's item, so wait until edits settle
    /// (e.g. the end of a drag) instead of doing it on every tiny change.
    private func scheduleTimelineRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            rebuildTimeline()
        }
    }

    /// Assembles the edited video and puts it in the player, keeping the playhead.
    private func rebuildTimeline() {
        timeEdits = currentTimeEdits()
        let resumeAt = currentTime
        let wasPlaying = player.rate > 0
        timeMap = TimeMap(edits: timeEdits, duration: duration)
        guard let built = try? CompositionBuilder.make(
            sources: sources, edits: timeEdits, canvas: previewSize, fps: metadata.fps, compositor: liveCompositor)
        else { return }
        composition = built
        updateCompositor()

        let item = AVPlayerItem(asset: built.asset)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix(microphoneVolume: style.microphoneVolume, systemVolume: style.systemVolume)
        item.audioTimePitchAlgorithm = .spectral  // sped-up voices keep their pitch
        player.replaceCurrentItem(with: item)
        applyTrim()
        seek(to: resumeAt)
        if wasPlaying { player.play() }
    }

    /// Reads the mic once in the background, then refreshes the automatic edits.
    private func detectSpeech() {
        guard let microphone = metadata.microphone else { return }
        let url = project.folder.appending(path: microphone.file)
        Task {
            speechRanges = await SpeechDetector.speech(in: url, offset: microphone.offset)
            if !editsAreCustom, style.speedUpIdle || style.cutsSilence { rebuildTimeline() }
        }
    }

    /// Trims away the dead time before your first action or word and after your last.
    func autoTrim() {
        let range = AutoEditPlanner.trim(from: cursorLog, speech: speechRanges, duration: duration)
        style.trimStart = range.lowerBound
        style.trimEnd = range.upperBound
        seek(to: range.lowerBound)
    }

    var editsAreCustom: Bool { style.timeEdits != nil }
    var selectedEdit: TimeEdit? { timeEdits.first { $0.id == selectedID } }

    func addEdit(_ kind: TimeEdit.Kind, at time: Double) {
        let edit = TimeEdit(kind: kind, start: max(0, time), end: min(duration, time + 2), speed: style.idleSpeed)
        style.timeEdits = (timeEdits + [edit]).sorted { $0.start < $1.start }
        selectedID = edit.id
    }

    func updateEdit(_ edit: TimeEdit) {
        var edits = timeEdits
        guard let index = edits.firstIndex(where: { $0.id == edit.id }) else { return }
        var changed = edit
        changed.start = min(max(0, changed.start), duration - 0.3)
        changed.end = min(duration, max(changed.end, changed.start + 0.3))
        edits[index] = changed
        style.timeEdits = edits.sorted { $0.start < $1.start }
    }

    /// Back to automatic edits (idle speed-ups, if turned on).
    func resetEdits() {
        style.timeEdits = nil
        selectedID = nil
    }

    // MARK: Timeline: zooms

    var zoomsAreEdited: Bool { style.zoomSegments != nil }
    var selectedZoom: ZoomSegment? { zoomSegments.first { $0.id == selectedID } }

    /// Any edit turns the automatic zooms into your own list, saved in style.json.
    func updateZoom(_ segment: ZoomSegment) {
        var segments = zoomSegments
        guard let index = segments.firstIndex(where: { $0.id == segment.id }) else { return }
        var changed = segment
        changed.start = min(max(0, changed.start), duration - 0.3)
        changed.end = min(duration, max(changed.end, changed.start + 0.3))
        segments[index] = changed
        style.zoomSegments = segments.sorted { $0.start < $1.start }
    }

    func addZoom(at time: Double) {
        let segment = ZoomSegment(start: max(0, time - 0.5), end: min(duration, time + 2), scale: style.zoomLevel)
        style.zoomSegments = (zoomSegments + [segment]).sorted { $0.start < $1.start }
        selectedID = segment.id
    }

    /// Back to the automatic zooms.
    func resetZooms() {
        style.zoomSegments = nil
        selectedID = nil
    }

    // MARK: Timeline: camera layouts

    var layoutSegments: [LayoutSegment] { style.cameraLayouts }
    var selectedLayout: LayoutSegment? { layoutSegments.first { $0.id == selectedID } }

    func addLayout(at time: Double) {
        let segment = LayoutSegment(start: max(0, time), end: min(duration, time + 3), layout: .camera)
        style.cameraLayouts = (layoutSegments + [segment]).sorted { $0.start < $1.start }
        selectedID = segment.id
    }

    func updateLayout(_ segment: LayoutSegment) {
        var segments = layoutSegments
        guard let index = segments.firstIndex(where: { $0.id == segment.id }) else { return }
        var changed = segment
        changed.start = min(max(0, changed.start), duration - 0.3)
        changed.end = min(duration, max(changed.end, changed.start + 0.3))
        segments[index] = changed
        style.cameraLayouts = segments.sorted { $0.start < $1.start }
    }

    // MARK: Timeline: text

    var textOverlays: [TextOverlay] { style.textOverlays }
    var selectedText: TextOverlay? { textOverlays.first { $0.id == selectedID } }

    func addText(at time: Double) {
        let overlay = TextOverlay(start: max(0, time), end: min(duration, time + 3))
        style.textOverlays = (textOverlays + [overlay]).sorted { $0.start < $1.start }
        selectedID = overlay.id
    }

    func updateText(_ overlay: TextOverlay) {
        var overlays = textOverlays
        guard let index = overlays.firstIndex(where: { $0.id == overlay.id }) else { return }
        var changed = overlay
        changed.start = min(max(0, changed.start), duration - 0.3)
        changed.end = min(duration, max(changed.end, changed.start + 0.3))
        overlays[index] = changed
        style.textOverlays = overlays.sorted { $0.start < $1.start }
    }

    // MARK: Captions

    var captions: [Caption] { style.captions ?? [] }

    func generateCaptions() {
        guard !isGeneratingCaptions, let microphone = metadata.microphone else { return }
        isGeneratingCaptions = true
        captionError = nil
        let url = project.folder.appending(path: microphone.file)
        Task {
            do {
                style.captions = try await CaptionGenerator.generate(from: url, offset: microphone.offset)
                if captions.isEmpty { captionError = "No speech found in the microphone recording." }
            } catch {
                captionError = error.localizedDescription
            }
            isGeneratingCaptions = false
        }
    }

    func updateCaption(_ caption: Caption) {
        guard var list = style.captions, let index = list.firstIndex(where: { $0.id == caption.id }) else { return }
        list[index] = caption
        style.captions = list
    }

    // MARK: Audio cleanup

    /// Makes microphone-clean.m4a the first time, then swaps it in (or back out).
    private func applyAudioCleanup() async {
        let wanted = style.cleansAudio
        if wanted, !FileManager.default.fileExists(atPath: project.cleanMicrophoneURL.path) {
            isCleaningAudio = true
            audioError = nil
            do {
                try await AudioCleaner.clean(project.microphoneURL, to: project.cleanMicrophoneURL)
            } catch {
                try? FileManager.default.removeItem(at: project.cleanMicrophoneURL)
                audioError = "Couldn't clean up the audio: \(error.localizedDescription)"
                isCleaningAudio = false
                style.cleansAudio = false
                return
            }
            isCleaningAudio = false
        }
        guard style.cleansAudio == wanted,
              let reloaded = try? await CompositionBuilder.loadSources(
                  project: project, metadata: metadata, cleanMicrophone: wanted)
        else { return }
        sources = reloaded
        rebuildTimeline()
    }

    /// Deletes the selected zoom, cut, speed-up or layout.
    func deleteSelected() {
        guard let id = selectedID else { return }
        if textOverlays.contains(where: { $0.id == id }) {
            style.textOverlays = textOverlays.filter { $0.id != id }
        } else if layoutSegments.contains(where: { $0.id == id }) {
            style.cameraLayouts = layoutSegments.filter { $0.id != id }
        } else if zoomSegments.contains(where: { $0.id == id }) {
            style.zoomSegments = zoomSegments.filter { $0.id != id }
        } else if timeEdits.contains(where: { $0.id == id }) {
            style.timeEdits = timeEdits.filter { $0.id != id }
        }
        selectedID = nil
    }

    // MARK: Timeline: trim & playhead

    var trimStart: Double { style.trimStart }
    var trimEnd: Double { style.trimEnd ?? duration }

    func setTrimStart(_ time: Double) {
        style.trimStart = min(max(0, time), trimEnd - 0.5)
        seek(to: style.trimStart)
    }

    func setTrimEnd(_ time: Double) {
        style.trimEnd = max(min(duration, time), trimStart + 0.5)
        seek(to: trimEnd)
    }

    /// Playback stays inside the trimmed part.
    private func applyTrim() {
        let start = timeMap.output(at: trimStart)
        let end = timeMap.output(at: trimEnd)
        player.currentItem?.reversePlaybackEndTime = CMTime(seconds: start, preferredTimescale: 600)
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 600)
        outputLength = max(0, end - start)
    }

    private func observePlayhead() {
        player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = self.timeMap.source(at: time.seconds)
                // Pressing play before the trimmed start jumps to it.
                if self.player.rate > 0, self.currentTime < self.trimStart - 0.05 { self.seek(to: self.trimStart) }
            }
        }
    }

    /// Jumps to a moment in recording time.
    func seek(to seconds: Double) {
        player.seek(
            to: CMTime(seconds: timeMap.output(at: seconds), preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Saves style.json shortly after the last change, not on every slider tick.
    private func scheduleSave() {
        saveTask?.cancel()
        let style = style
        let url = project.styleURL
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            try? style.save(to: url)
        }
    }

    // MARK: Export

    func export() {
        guard exportProgress == nil else { return }
        exportProgress = 0
        exportedURL = nil
        exportError = nil
        player.pause()

        let project = project
        let metadata = metadata
        var compositor = liveCompositor.current
        compositor.timeMap = TimeMap(edits: currentTimeEdits(), duration: duration)
        let resolution = resolution
        exportTask = Task {
            do {
                exportedURL = try await VideoExporter.export(
                    project: project, metadata: metadata, compositor: compositor, resolution: resolution
                ) { value in
                    Task { @MainActor in
                        if self.exportProgress != nil { self.exportProgress = value }
                    }
                }
            } catch is CancellationError {
                // The user cancelled; nothing to report.
            } catch {
                exportError = error.localizedDescription
            }
            exportProgress = nil
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }
}

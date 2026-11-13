import AppKit
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

    /// The current frame redrawn with new settings while paused. Shown over
    /// the player, so changes appear instantly instead of waiting for a seek.
    private(set) var stillFrame: CGImage?
    @ObservationIgnored private var isRenderingStill = false
    @ObservationIgnored private var stillIsStale = false

    /// Earlier versions of the settings, for ⌘Z.
    private var undoStack: [ExportStyle] = []
    private var redoStack: [ExportStyle] = []
    @ObservationIgnored private var lastUndoMark = Date.distantPast
    @ObservationIgnored private var isRestoringStyle = false
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// 0…1 while exporting, nil otherwise.
    private(set) var exportProgress: Double?
    private(set) var exportedURL: URL?
    private(set) var exportError: String?

    @ObservationIgnored private let cursorLog: CursorLog
    /// When you're talking (from the mic), so automatic edits never touch it.
    @ObservationIgnored private var speechRanges: [ClosedRange<Double>] = []
    /// Separate bursts of voice, for finding filler sounds.
    @ObservationIgnored private var voicedRanges: [ClosedRange<Double>] = []
    @ObservationIgnored private let sprites: CursorSprites
    @ObservationIgnored private var cursorTrack: CursorTrack
    @ObservationIgnored private var cameraTrack: CameraTrack?
    @ObservationIgnored private var zoomActivities: [ZoomActivity] = []
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
        if !isRestoringStyle { recordUndo(old) }
        defer { scheduleSave() }
        if style.cleansAudio != old.cleansAudio {
            Task { await applyAudioCleanup() }
        }
        if style.timeEdits != old.timeEdits || style.dismissedEdits != old.dismissedEdits || style.speedUpIdle != old.speedUpIdle || style.idleSpeed != old.idleSpeed
            || style.cutsSilence != old.cutsSilence || style.silenceLength != old.silenceLength
            || style.removesFillers != old.removesFillers
            || (style.removesFillers && style.captions?.map(\.words) != old.captions?.map(\.words)) {
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
            || style.typingZoomLevel != old.typingZoomLevel
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
            zoomActivities = activities
            zoomSegments = style.zoomSegments
                ?? ZoomPlanner.segments(
                    for: activities, duration: duration, scale: style.zoomLevel, typingScale: style.typingZoomLevel)
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
            sourceScale: cursorLog.scale, timeMap: timeMap, assetFolder: project.folder)

        // A paused player doesn't redraw by itself. Redraw the last frame
        // ourselves: instant, unlike seeking (which decodes video again).
        if player.rate == 0 {
            if liveCompositor.lastFrame != nil {
                renderStill()
            } else {
                player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    /// One redraw at a time; if settings change meanwhile, one more after it.
    private func renderStill() {
        guard let frame = liveCompositor.lastFrame else { return }
        guard !isRenderingStill else {
            stillIsStale = true
            return
        }
        isRenderingStill = true
        let compositor = liveCompositor
        let size = previewSize
        Task {
            let image = await Task.detached(priority: .userInitiated) {
                compositor.still(of: frame, canvas: size)
            }.value
            isRenderingStill = false
            if player.rate == 0 { stillFrame = image }
            if stillIsStale {
                stillIsStale = false
                renderStill()
            }
        }
    }

    // MARK: Undo

    /// Quick successive changes (a slider drag) undo as one step.
    private func recordUndo(_ old: ExportStyle) {
        if Date.now.timeIntervalSince(lastUndoMark) > 0.6 || undoStack.isEmpty {
            undoStack.append(old)
            if undoStack.count > 200 { undoStack.removeFirst() }
        }
        lastUndoMark = .now
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(style)
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(style)
        restore(next)
    }

    private func restore(_ saved: ExportStyle) {
        isRestoringStyle = true
        style = saved
        isRestoringStyle = false
        lastUndoMark = .distantPast
        selectedID = nil
    }

    // MARK: Timeline: cuts & speed-ups

    /// Which edits in `timeEdits` are automatic (not made or changed by you).
    @ObservationIgnored private var automaticEditIDs: Set<UUID> = []

    /// Your own edits, plus the automatic ones that don't clash with them or
    /// with automatic ones you removed.
    private func currentTimeEdits() -> [TimeEdit] {
        let own = style.timeEdits ?? []
        let blocked = own + style.dismissedEdits
        let automatic = automaticTimeEdits().filter { edit in
            !blocked.contains { $0.start < edit.end && edit.start < $0.end }
        }
        automaticEditIDs = Set(automatic.map(\.id))
        return (own + automatic).sorted { $0.start < $1.start }
    }

    private func automaticTimeEdits() -> [TimeEdit] {
        AutoEditPlanner.edits(
            from: cursorLog, speech: speechRanges, duration: duration,
            speedUp: style.speedUpIdle, speed: style.idleSpeed,
            cutSilence: style.cutsSilence, silenceLength: style.silenceLength,
            fillers: style.removesFillers
                ? FillerDetector.fillers(voiced: voicedRanges, words: captions.flatMap { $0.words ?? [] })
                : [])
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
        stillFrame = nil
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
            let result = await SpeechDetector.speech(in: url, offset: microphone.offset)
            speechRanges = result.speech
            voicedRanges = result.voiced
            if style.autoTrim {
                // Speech can move the trim; not a change worth undoing.
                isRestoringStyle = true
                applyAutoTrim()
                isRestoringStyle = false
            }
            if style.speedUpIdle || style.cutsSilence || style.removesFillers { rebuildTimeline() }
        }
    }

    /// On: trims away the dead time before your first action or word and
    /// after your last. Off: back to the whole recording.
    func setAutoTrim(_ on: Bool) {
        var changed = style
        changed.autoTrim = on
        if !on {
            changed.trimStart = 0
            changed.trimEnd = nil
        }
        style = changed
        if on { applyAutoTrim() }
        seek(to: trimStart)
    }

    private func applyAutoTrim() {
        let range = AutoEditPlanner.trim(from: cursorLog, speech: speechRanges, duration: duration)
        var changed = style
        changed.trimStart = range.lowerBound
        changed.trimEnd = range.upperBound
        style = changed
    }

    /// How many automatic edits of a kind are on the timeline now.
    func automaticEditCount(_ kind: TimeEdit.Kind) -> Int {
        timeEdits.filter { $0.kind == kind && automaticEditIDs.contains($0.id) }.count
    }

    /// You've added, changed or removed cuts or speed-ups yourself.
    var editsAreCustom: Bool { !(style.timeEdits ?? []).isEmpty || !style.dismissedEdits.isEmpty }
    var selectedEdit: TimeEdit? { timeEdits.first { $0.id == selectedID } }

    func addEdit(_ kind: TimeEdit.Kind, at time: Double) {
        let edit = TimeEdit(kind: kind, start: max(0, time), end: min(duration, time + 2), speed: style.idleSpeed)
        style.timeEdits = ((style.timeEdits ?? []) + [edit]).sorted { $0.start < $1.start }
        selectedID = edit.id
    }

    /// Changing an automatic edit makes it yours.
    func updateEdit(_ edit: TimeEdit) {
        guard let original = timeEdits.first(where: { $0.id == edit.id }) else { return }
        var changed = edit
        changed.start = min(max(0, changed.start), duration - 0.3)
        changed.end = min(duration, max(changed.end, changed.start + 0.3))
        var updated = style
        var own = (updated.timeEdits ?? []).filter { $0.id != edit.id }
        if automaticEditIDs.contains(edit.id) { updated.dismissedEdits.append(original) }
        own.append(changed)
        updated.timeEdits = own.sorted { $0.start < $1.start }
        style = updated
    }

    /// Back to only the automatic edits.
    func resetEdits() {
        var updated = style
        updated.timeEdits = nil
        updated.dismissedEdits = []
        style = updated
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

    /// Where a zoom looks, 0…1 across and down the screen (yours or automatic);
    /// nil while it follows the cursor.
    func zoomTarget(_ zoom: ZoomSegment) -> CGPoint? {
        let size = CGSize(width: cursorLog.width, height: cursorLog.height)
        return ZoomPlanner.anchor(for: zoom, activities: zoomActivities, screenSize: size)
            .map { CGPoint(x: $0.x / size.width, y: $0.y / size.height) }
    }

    @ObservationIgnored private var screenMapCache: CGImage?

    /// A small picture of the whole screen (no zoom), for choosing a zoom's target.
    var screenMap: CGImage? {
        if let screenMapCache { return screenMapCache }
        screenMapCache = liveCompositor.screenThumbnail(width: 520)
        return screenMapCache
    }

    /// Back to the automatic zooms.
    func resetZooms() {
        style.zoomSegments = nil
        selectedID = nil
    }

    // MARK: Timeline: camera layouts

    var layoutSegments: [LayoutSegment] { style.cameraLayouts }

    /// Whether this layout appears anywhere in the video (whole-video or a block).
    func usesLayout(_ layout: CameraLayout) -> Bool {
        style.baseLayout == layout || layoutSegments.contains { $0.layout == layout }
    }
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

    // MARK: Background picture

    private(set) var backgroundError: String?
    @ObservationIgnored private var thumbnailCache: (name: String, image: NSImage)?

    /// A small copy of the background picture for the settings panel.
    var backgroundThumbnail: NSImage? {
        guard let name = style.backgroundImage else { return nil }
        if let cached = thumbnailCache, cached.name == name { return cached.image }
        let url = project.folder.appending(path: name)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 600,
              ] as CFDictionary)
        else { return nil }
        let thumbnail = NSImage(cgImage: image, size: .zero)
        thumbnailCache = (name, thumbnail)
        return thumbnail
    }

    /// Copies the picture into the recording's folder and uses it.
    func useBackgroundImage(_ url: URL) {
        backgroundError = nil
        do {
            let name = try BackgroundImage.importImage(from: url, into: project.folder)
            if let old = style.backgroundImage { try? FileManager.default.removeItem(at: project.folder.appending(path: old)) }
            var changed = style
            changed.backgroundImage = name
            changed.backgroundKind = .image
            style = changed
        } catch {
            backgroundError = "Couldn't use that picture. Try a JPEG, PNG or HEIC."
        }
    }

    func useDesktopWallpaper() {
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            backgroundError = "Couldn't find your wallpaper."
            return
        }
        useBackgroundImage(url)
        if backgroundError != nil { backgroundError = "Your wallpaper can't be used (moving wallpapers aren't supported). Choose a picture instead." }
    }

    /// Captions made with word timings (captions from before this feature have none).
    var canRemoveFillers: Bool { captions.contains { $0.words?.isEmpty == false } }

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
        } else if let edit = timeEdits.first(where: { $0.id == id }) {
            if automaticEditIDs.contains(id) {
                style.dismissedEdits.append(edit)  // don't bring it back
            } else {
                style.timeEdits = (style.timeEdits ?? []).filter { $0.id != id }
            }
        }
        selectedID = nil
    }

    // MARK: Timeline: trim & playhead

    var trimStart: Double { style.trimStart }
    var trimEnd: Double { style.trimEnd ?? duration }

    /// Dragging a handle is your own trim, so auto-trim switches off.
    func setTrimStart(_ time: Double) {
        style.autoTrim = false
        style.trimStart = min(max(0, time), trimEnd - 0.5)
        seek(to: style.trimStart)
    }

    func setTrimEnd(_ time: Double) {
        style.autoTrim = false
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
                if self.player.rate > 0 { self.stillFrame = nil }
                // Pressing play before the trimmed start jumps to it.
                if self.player.rate > 0, self.currentTime < self.trimStart - 0.05 { self.seek(to: self.trimStart) }
            }
        }
    }

    /// Space bar: play, or pause. Playing from the end starts again at the trim start.
    func togglePlay() {
        if player.rate > 0 {
            player.pause()
            return
        }
        if currentTime >= trimEnd - 0.05 || currentTime < trimStart { seek(to: trimStart) }
        stillFrame = nil
        player.play()
    }

    /// Jumps to a moment in recording time.
    func seek(to seconds: Double) {
        stillFrame = nil
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
        // Always export with the settings as they are right now. (The preview's
        // copy isn't refreshed by trim or volume changes, so on its own it
        // could be one change behind.)
        compositor.style = style
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

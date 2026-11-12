import AppKit
import AVFoundation
import Observation
import os

/// What the recorder is doing right now. The UI is drawn from this.
enum RecorderPhase: Equatable {
    case idle
    case countdown(Int)
    case recording(since: Date)
    case saving
}

/// What the user picked. We keep IDs (not ScreenCaptureKit objects) so the
/// choice survives refreshing the list.
enum CaptureSelection: Hashable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
}

/// What the main window's sidebar has selected.
enum SidebarItem: Hashable {
    case recorder
    case project(RecordingProject)
}

@MainActor
@Observable
final class AppState {
    static let mainWindowID = "main"

    var permissionGranted = ScreenRecordingPermission.isGranted
    var sources = CaptureSources()
    var selection: CaptureSelection?
    var phase: RecorderPhase = .idle
    var lastRecording: RecordingSession.Result?
    var errorMessage: String?
    var projects: [RecordingProject] = []
    var sidebarSelection: SidebarItem? = .recorder

    // Camera & audio. The choices are remembered between launches.
    var cameras: [AVCaptureDevice] = []
    var microphones: [AVCaptureDevice] = []
    var selectedCameraID = UserDefaults.standard.string(forKey: "cameraID") {
        didSet { UserDefaults.standard.set(selectedCameraID, forKey: "cameraID") }
    }
    var selectedMicrophoneID = UserDefaults.standard.string(forKey: "microphoneID") {
        didSet { UserDefaults.standard.set(selectedMicrophoneID, forKey: "microphoneID") }
    }
    /// Record Closeup's own windows too (the countdown and camera preview stay hidden).
    var includesCloseup = UserDefaults.standard.bool(forKey: "includesCloseup") {
        didSet { UserDefaults.standard.set(includesCloseup, forKey: "includesCloseup") }
    }
    var recordsSystemAudio = UserDefaults.standard.bool(forKey: "recordsSystemAudio") {
        didSet { UserDefaults.standard.set(recordsSystemAudio, forKey: "recordsSystemAudio") }
    }

    private var recordingOptions: RecordingOptions {
        RecordingOptions(
            camera: cameras.first { $0.uniqueID == selectedCameraID },
            microphone: microphones.first { $0.uniqueID == selectedMicrophoneID },
            systemAudio: recordsSystemAudio)
    }

    /// Set by the menu bar label, which is always alive, so we can reopen the
    /// main window even after the user closed it.
    @ObservationIgnored var openMainWindow: (() -> Void)?

    @ObservationIgnored private var session: RecordingSession?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private let countdown = CountdownOverlay()
    @ObservationIgnored private let cameraPreview = CameraPreview()
    @ObservationIgnored private var hotKey: GlobalHotKey?
    @ObservationIgnored private var hiddenWindows: [NSWindow] = []

    let updates = UpdateChecker()

    init() {
        RecordingProject.moveOldLibrary()
        updates.checkIfDue()
        hotKey = GlobalHotKey { [weak self] in self?.toggleRecording() }

        // Re-check permission whenever the user comes back from System Settings.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermission() }
        }
        refreshProjects()
        Task { await refreshSources() }
        #if DEBUG
        runAutoRecordIfRequested()
        #endif
    }

    #if DEBUG
    /// Test hook for debugging the recorder from Terminal:
    ///     open Closeup.app --args -autoRecord 10
    /// records the main display for 10 s (no countdown), saves, and quits.
    private func runAutoRecordIfRequested() {
        // Also: `-exportProject "/path/to/Recording …"` exports that recording
        // at 1080p with its saved style, then quits.
        if let path = UserDefaults.standard.string(forKey: "exportProject") {
            Task {
                do {
                    let model = try await ProjectEditorModel.load(RecordingProject(folder: URL(fileURLWithPath: path)))
                    model.export()
                    while model.exportProgress != nil { try? await Task.sleep(for: .milliseconds(200)) }
                    Logger.recording.info("Export: \(model.exportedURL?.path ?? model.exportError ?? "?", privacy: .public)")
                } catch {
                    Logger.recording.error("Export failed: \(String(describing: error), privacy: .public)")
                }
                NSApp.terminate(nil)
            }
            return
        }

        let seconds = UserDefaults.standard.double(forKey: "autoRecord")
        guard seconds > 0 else { return }
        Task {
            await refreshSources()
            guard let display = sources.displays.first else { return }
            do {
                let session = try RecordingSession(
                    target: .display(display, excluding: sources.ownApplication), options: recordingOptions)
                try await session.prepare()
                try await session.start()
                self.session = session
                phase = .recording(since: .now)
                try? await Task.sleep(for: .seconds(seconds))
                await stopRecording()
            } catch {
                Logger.recording.error("Auto-record failed: \(error.localizedDescription, privacy: .public)")
            }
            NSApp.terminate(nil)
        }
    }
    #endif

    // MARK: Projects

    func refreshProjects() {
        projects = RecordingProject.all()
    }

    func moveToTrash(_ project: RecordingProject) {
        try? FileManager.default.trashItem(at: project.folder, resultingItemURL: nil)
        if sidebarSelection == .project(project) { sidebarSelection = .recorder }
        refreshProjects()
    }

    // MARK: Permission & sources

    func refreshPermission() {
        let granted = ScreenRecordingPermission.isGranted
        guard granted != permissionGranted else { return }
        permissionGranted = granted
        if granted { Task { await refreshSources() } }
    }

    func refreshSources() async {
        // Listing cameras and mics doesn't ask for permission; using them does.
        cameras = CaptureDevices.cameras
        microphones = CaptureDevices.microphones
        guard permissionGranted else { return }
        do {
            sources = try await CaptureSources.load()
            if !isValid(selection) {
                selection = sources.displays.first.map { .display($0.id) }
            }
        } catch {
            errorMessage = "Couldn't list displays and windows: \(error.localizedDescription)"
        }
    }

    private func isValid(_ selection: CaptureSelection?) -> Bool {
        switch selection {
        case .display(let id): sources.displays.contains { $0.id == id }
        case .window(let id): sources.windows.contains { $0.id == id }
        case nil: false
        }
    }

    // MARK: Recording

    var recordActionTitle: String {
        switch phase {
        case .idle: "Start Recording"
        case .countdown: "Cancel Countdown"
        case .recording: "Stop Recording"
        case .saving: "Saving"
        }
    }

    /// Start → countdown → record → stop. Bound to the button, menu and hotkey.
    func toggleRecording() {
        Logger.recording.info("Toggle recording (phase: \(String(describing: self.phase), privacy: .public))")
        switch phase {
        case .idle: startCountdown()
        case .countdown: cancelCountdown()
        case .recording: Task { await stopRecording() }
        case .saving: break
        }
    }

    private func startCountdown() {
        guard permissionGranted else {
            showMainWindow()
            return
        }
        errorMessage = nil
        phase = .countdown(3)

        countdownTask = Task {
            do {
                // Refresh first: the window may have moved or resized since the list loaded.
                await refreshSources()
                guard let target = makeTarget() else { throw RecordingError.noSourceSelected }
                let session = try RecordingSession(target: target, options: recordingOptions)
                self.session = session
                // Camera/mic permission prompts appear here, before the countdown,
                // and the camera warms up while we count.
                try await session.prepare()
                if Task.isCancelled { return }

                // Out of the way, unless you're filming Closeup itself.
                if !includesCloseup { hideMainWindow() }
                if session.hasCamera {
                    let preview = cameraPreview
                    preview.show(on: target.screen)
                    session.onCameraFrame { frame in preview.display(frame) }
                }
                for number in [3, 2, 1] {
                    phase = .countdown(number)
                    countdown.show(number, on: target.screen)
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { return }
                }
                countdown.hide()

                // AppState lives as long as the app, so a strong reference is fine.
                session.onUnexpectedStop = { _ in
                    Task { await self.stopRecording() }
                }
                try await session.start()
                phase = .recording(since: .now)
            } catch {
                await discardSession()
                fail(error)
            }
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown.hide()
        phase = .idle
        Task { await discardSession() }
        showMainWindow()
    }

    private func discardSession() async {
        let session = self.session
        self.session = nil
        cameraPreview.hide()
        await session?.cancel()
    }

    private func makeTarget() -> CaptureTarget? {
        switch selection {
        case .display(let id):
            sources.displays.first { $0.id == id }.map {
                .display($0, excluding: sources.ownApplication, keeping: includesCloseup ? sources.ownWindows : [])
            }
        case .window(let id):
            sources.windows.first { $0.id == id }.map { .window($0) }
        case nil:
            nil
        }
    }

    func stopRecording() async {
        guard case .recording = phase, let session else { return }
        phase = .saving
        self.session = nil
        cameraPreview.hide()
        do {
            let result = try await session.stop()
            lastRecording = result
            Logger.recording.info("Saved \(result.project.name, privacy: .public)")
            // Jump straight into the editor for the new recording.
            refreshProjects()
            sidebarSelection = .project(result.project)
        } catch {
            Logger.recording.error("Stop failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Recording failed: \(error.localizedDescription)"
        }
        phase = .idle
        showMainWindow()
    }

    private func fail(_ error: Error) {
        countdown.hide()
        phase = .idle
        errorMessage = error.localizedDescription
        showMainWindow()
    }

    // MARK: Windows & Finder

    /// Get our window out of the way while recording.
    private func hideMainWindow() {
        hiddenWindows = NSApp.windows.filter {
            $0.isVisible && ($0.identifier?.rawValue.hasPrefix(Self.mainWindowID) ?? false)
        }
        hiddenWindows.forEach { $0.orderOut(nil) }
    }

    func showMainWindow() {
        if hiddenWindows.isEmpty {
            openMainWindow?()
        } else {
            hiddenWindows.forEach { $0.makeKeyAndOrderFront(nil) }
            hiddenWindows = []
        }
        // Come to the front even if you clicked another app while recording.
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.identifier?.rawValue.hasPrefix(Self.mainWindowID) ?? false {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    func revealLibrary() {
        let folder = RecordingProject.libraryFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// Renames a recording. If it's open, the editor reopens it at its new place.
    func rename(_ project: RecordingProject, to title: String) {
        do {
            let renamed = try project.renamed(to: title)
            let wasSelected = sidebarSelection == .project(project)
            refreshProjects()
            if wasSelected { sidebarSelection = .project(renamed) }
        } catch CocoaError.fileWriteFileExists {
            errorMessage = "There's already a recording called \"\(title)\"."
        } catch {
            errorMessage = "Couldn't rename the recording."
        }
    }

    func reveal(_ project: RecordingProject) {
        NSWorkspace.shared.activateFileViewerSelecting([project.videoURL])
    }

    func play(_ project: RecordingProject) {
        NSWorkspace.shared.open(project.videoURL)
    }
}

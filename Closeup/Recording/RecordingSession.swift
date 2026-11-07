import AVFoundation

/// What to record besides the screen.
struct RecordingOptions {
    var camera: AVCaptureDevice?
    var microphone: AVCaptureDevice?
    var systemAudio = false
}

/// One recording from start to finish: runs the screen recorder, cursor
/// logger, camera and microphone side by side, then writes the project folder.
///
///     prepare()  ask for camera/mic access and warm the camera up (during the countdown)
///     start()    start the screen and cursor
///     stop()     finish every file and write project.json
@MainActor
final class RecordingSession {
    static let framesPerSecond = 60

    struct Result {
        let project: RecordingProject
        let metadata: RecordingMetadata
    }

    let target: CaptureTarget
    private let options: RecordingOptions
    private let project: RecordingProject
    private let recorder: ScreenRecorder
    private let cursorLogger: CursorLogger
    private var deviceRecorder: DeviceRecorder?
    private let createdAt = Date()

    /// Called on the main actor if capture stops without us asking.
    var onUnexpectedStop: ((Error) -> Void)?

    init(target: CaptureTarget, options: RecordingOptions) throws {
        self.target = target
        self.options = options
        project = try RecordingProject.create(at: createdAt)
        do {
            recorder = try ScreenRecorder(
                target: target, fps: Self.framesPerSecond, outputURL: project.videoURL,
                systemAudioURL: options.systemAudio ? project.systemAudioURL : nil)
        } catch {
            project.delete()
            throw error
        }
        cursorLogger = CursorLogger(target: target, shapesFolder: project.cursorsFolder)
        recorder.onUnexpectedStop = { [weak self] error in
            Task { @MainActor in self?.onUnexpectedStop?(error) }
        }
    }

    /// Asks for camera/mic access (macOS shows its prompt the first time) and
    /// starts them, so the camera has adjusted its exposure by the time
    /// recording starts.
    func prepare() async throws {
        guard options.camera != nil || options.microphone != nil else { return }
        if options.camera != nil, !(await AVCaptureDevice.requestAccess(for: .video)) {
            throw RecordingError.cameraAccessDenied
        }
        if options.microphone != nil, !(await AVCaptureDevice.requestAccess(for: .audio)) {
            throw RecordingError.microphoneAccessDenied
        }
        let devices = try DeviceRecorder(
            camera: options.camera, microphone: options.microphone,
            cameraURL: project.cameraURL, microphoneURL: project.microphoneURL)
        await devices.start()
        deviceRecorder = devices
    }

    var hasCamera: Bool { deviceRecorder?.hasCamera ?? false }

    /// Live camera frames, for the preview bubble while recording.
    func onCameraFrame(_ handler: @escaping (CVPixelBuffer) -> Void) {
        deviceRecorder?.onCameraFrame = handler
    }

    func start() async throws {
        // Start logging first so the cursor position is known when frame 1 lands.
        cursorLogger.start()
        do {
            try await recorder.start()
        } catch {
            _ = cursorLogger.stop()
            await cancel()
            throw error
        }
    }

    /// Throws everything away (e.g. the countdown was cancelled).
    func cancel() async {
        _ = await deviceRecorder?.stop()
        deviceRecorder = nil
        project.delete()
    }

    func stop() async throws -> Result {
        // Freeze "the end" before anything else, so every file ends together.
        let endTime = HostClock.now
        let (rawEvents, shapes) = cursorLogger.stop()

        let screen: ScreenRecorder.Summary
        do {
            screen = try await recorder.stop(at: endTime)
        } catch {
            await cancel()
            throw error
        }
        let devices = await deviceRecorder?.stop()
        let video = screen.video

        let cursorLog = CursorLog(
            scale: target.scale,
            width: target.frame.width,
            height: target.frame.height,
            shapes: shapes.isEmpty ? nil : shapes,
            events: Self.videoTimeline(rawEvents, videoStart: video.firstFrameTime, videoEnd: video.endTime))

        /// Where each extra file sits on the screen video's timeline.
        func track(_ url: URL, start: Double?, device: AVCaptureDevice? = nil) -> RecordingMetadata.MediaTrack? {
            start.map {
                .init(file: url.lastPathComponent, offset: $0 - video.firstFrameTime, deviceName: device?.localizedName)
            }
        }

        let metadata = RecordingMetadata(
            createdAt: createdAt,
            source: .init(kind: target.kind, name: target.name, displayID: target.displayID, windowID: target.windowID),
            captureFrame: Rect(target.frame),
            scale: target.scale,
            videoWidth: target.pixelWidth,
            videoHeight: target.pixelHeight,
            fps: Self.framesPerSecond,
            duration: video.duration,
            frameCount: video.frameCount,
            droppedFrameCount: video.droppedFrameCount,
            displays: ScreenGeometry.displaySnapshot(),
            camera: track(project.cameraURL, start: devices?.cameraStart, device: options.camera),
            microphone: track(project.microphoneURL, start: devices?.microphoneStart, device: options.microphone),
            systemAudio: track(project.systemAudioURL, start: screen.systemAudioStart))

        try project.write(metadata: metadata, cursor: cursorLog)
        return Result(project: project, metadata: metadata)
    }

    /// Re-times raw events so t = 0 is the first video frame.
    /// Events before the first frame collapse into one starting position and shape.
    private static func videoTimeline(
        _ raw: [CursorLogger.RawEvent], videoStart: Double, videoEnd: Double
    ) -> [CursorEvent] {
        var events: [CursorEvent] = []
        var positionAtStart: CGPoint?
        var shapeAtStart: Int?

        for event in raw {
            let t = event.hostTime - videoStart
            if t < 0 {
                positionAtStart = event.position
                if let shape = event.shape { shapeAtStart = shape }
                continue
            }
            if event.hostTime > videoEnd { break }
            events.append(CursorEvent(
                t: t, x: event.position.x, y: event.position.y, type: event.type, shape: event.shape))
        }

        var start: [CursorEvent] = []
        if let position = positionAtStart {
            start.append(CursorEvent(t: 0, x: position.x, y: position.y, type: .move))
            if let shape = shapeAtStart {
                start.append(CursorEvent(t: 0, x: position.x, y: position.y, type: .shape, shape: shape))
            }
        }
        return start + events
    }
}

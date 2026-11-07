import AVFoundation

/// The cameras and microphones the user can pick from.
enum CaptureDevices {
    static var cameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices
    }

    static var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified
        ).devices
    }
}

/// Records the webcam and the microphone with AVFoundation, each into its
/// own file (camera.mov, microphone.m4a), so each stays editable.
final class DeviceRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {

    struct Summary {
        /// Host-clock seconds where each file starts; nil if nothing was recorded.
        let cameraStart: Double?
        let microphoneStart: Double?
    }

    private let session = AVCaptureSession()
    var hasCamera: Bool { cameraWriter != nil }
    /// Each camera frame, for the live preview. Called on the camera queue.
    nonisolated(unsafe) var onCameraFrame: ((CVPixelBuffer) -> Void)?
    private let cameraQueue = DispatchQueue(label: "app.closeup.camera", qos: .userInitiated)
    private let microphoneQueue = DispatchQueue(label: "app.closeup.microphone", qos: .userInitiated)
    private var cameraWriter: MediaFileWriter?
    private var microphoneWriter: MediaFileWriter?

    /// Needs camera/mic permission already granted.
    init(camera: AVCaptureDevice?, microphone: AVCaptureDevice?, cameraURL: URL, microphoneURL: URL) throws {
        super.init()
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if let camera {
            let input = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(input) { session.addInput(input) }
            // 720p is plenty for a bubble a few hundred pixels wide.
            if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }

            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: cameraQueue)
            if session.canAddOutput(output) { session.addOutput(output) }
            cameraWriter = MediaFileWriter(
                url: cameraURL, fileType: .mov, mediaType: .video, queue: cameraQueue,
                settings: MediaFileWriter.cameraSettings)
        }

        if let microphone {
            let input = try AVCaptureDeviceInput(device: microphone)
            if session.canAddInput(input) { session.addInput(input) }
            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(self, queue: microphoneQueue)
            if session.canAddOutput(output) { session.addOutput(output) }
            microphoneWriter = MediaFileWriter(
                url: microphoneURL, fileType: .m4a, mediaType: .audio, queue: microphoneQueue,
                settings: MediaFileWriter.audioSettings)
        }
    }

    /// Starts the camera and mic. Files start filling right away; anything
    /// before the first screen frame is trimmed off at export.
    func start() async {
        // startRunning blocks while the hardware wakes up, so keep it off the main thread.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                session.startRunning()
                continuation.resume()
            }
        }
    }

    func stop() async -> Summary {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                session.stopRunning()
                continuation.resume()
            }
        }
        return Summary(
            cameraStart: await cameraWriter?.finish(),
            microphoneStart: await microphoneWriter?.finish())
    }

    // MARK: Sample delegates (camera and mic share this one method)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Capture devices can run on their own clock; translate to the host
        // clock so camera and mic line up with the screen and cursor.
        let hostTime = CMSyncConvertTime(
            sampleBuffer.presentationTimeStamp,
            from: session.synchronizationClock ?? CMClockGetHostTimeClock(),
            to: CMClockGetHostTimeClock())
        if output is AVCaptureVideoDataOutput {
            cameraWriter?.append(sampleBuffer, hostTime: hostTime)
            if let frame = sampleBuffer.imageBuffer { onCameraFrame?(frame) }
        } else {
            microphoneWriter?.append(sampleBuffer, hostTime: hostTime)
        }
    }
}

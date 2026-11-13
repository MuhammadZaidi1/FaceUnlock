import AVFoundation
import Combine
import Vision

/// Session configuration, capture callbacks, and Vision work share one serial queue.
/// Only published UI values and presentationID are accessed on the main thread.
final class CameraController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published private(set) var message = "Camera is stopped"
    @Published private(set) var faceCount = 0
    @Published private(set) var isStreaming = false
    @Published private(set) var permissionDenied = false

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.faceunlock.camera", qos: .userInitiated)
    private var presentationID: UUID?
    private var activeID: UUID?
    private var observers: [NSObjectProtocol] = []
    private var lastDetectionTime = 0.0
    private var interrupted = false

    override init() {
        super.init()
        let center = NotificationCenter.default
        for name in [AVCaptureSession.wasInterruptedNotification,
                     AVCaptureSession.interruptionEndedNotification,
                     AVCaptureSession.runtimeErrorNotification,
                     AVCaptureSession.didStopRunningNotification,
                     AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                // Extract values before crossing queues; do not retain camera frames.
                let isOurSession = (notification.object as? AVCaptureSession) === self?.session
                let deviceID = (notification.object as? AVCaptureDevice)?.uniqueID
                let error = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription
                self?.queue.async { [weak self] in
                    self?.handle(name, isOurSession: isOurSession, deviceID: deviceID, error: error)
                }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Called only when the setup window opens or the user explicitly retries.
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        let id = UUID()
        presentationID = id
        message = "Checking camera permission…"
        faceCount = 0
        isStreaming = false
        permissionDenied = false
        queue.async { [weak self] in
            guard let self else { return }
            self.tearDown()
            self.activeID = id
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                self.configureAndStart(id)
            case .notDetermined:
                self.publish(id, "Waiting for camera permission…")
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    self?.queue.async { [weak self] in
                        guard let self, self.activeID == id else { return }
                        if granted { self.configureAndStart(id) }
                        else { self.publish(id, "Camera access denied. Allow FaceUnlock in System Settings → Privacy & Security → Camera.", denied: true) }
                    }
                }
            case .denied:
                self.publish(id, "Camera access denied. Allow FaceUnlock in System Settings → Privacy & Security → Camera.", denied: true)
            case .restricted:
                self.publish(id, "Camera access is restricted by macOS or device management.")
            @unknown default:
                self.publish(id, "Camera permission is unavailable on this system.")
            }
        }
    }

    func stop(wait: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        // Invalidates queued UI updates and permission replies before stopping capture.
        presentationID = nil
        faceCount = 0
        isStreaming = false
        message = "Camera is stopped"
        let work = { [self] in
            activeID = nil
            tearDown()
        }
        if wait { queue.sync(execute: work) }
        else { queue.async(execute: work) }
    }

    private func configureAndStart(_ id: UUID) {
        guard activeID == id else { return }
        guard let device = AVCaptureDevice.default(for: .video) else {
            publish(id, "No camera available. Connect a camera, then choose Retry.")
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(self, queue: queue)
            session.beginConfiguration()
            if session.canSetSessionPreset(.medium) { session.sessionPreset = .medium }
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                publish(id, "Unable to use this camera. Close other camera apps, then retry.")
                return
            }
            session.addInput(input)
            guard session.canAddOutput(output) else {
                session.removeInput(input)
                session.commitConfiguration()
                publish(id, "Camera video output is unavailable.")
                return
            }
            session.addOutput(output)
            session.commitConfiguration()
            lastDetectionTime = 0
            publish(id, "Starting camera…")
            session.startRunning()
            if !session.isRunning {
                publish(id, "Camera could not start. Close other camera apps, then retry.")
            }
        } catch {
            publish(id, "Unable to open camera: \(error.localizedDescription)")
        }
    }

    private func tearDown() {
        interrupted = false
        session.stopRunning()
        session.beginConfiguration()
        for output in session.outputs {
            (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
            session.removeOutput(output)
        }
        session.inputs.forEach(session.removeInput)
        session.commitConfiguration()
    }

    private func handle(_ name: Notification.Name, isOurSession: Bool, deviceID: String?, error: String?) {
        guard let id = activeID else { return }
        if name == AVCaptureDevice.wasDisconnectedNotification {
            guard session.inputs.compactMap({ ($0 as? AVCaptureDeviceInput)?.device.uniqueID }).contains(deviceID ?? "") else { return }
            tearDown()
            publish(id, "Camera disconnected. Reconnect it, then choose Retry.")
            return
        }
        guard isOurSession else { return }
        switch name {
        case AVCaptureSession.wasInterruptedNotification:
            interrupted = true
            publish(id, "Camera interrupted. Waiting for it to become available…")
        case AVCaptureSession.interruptionEndedNotification:
            interrupted = false
            // AVFoundation normally resumes automatically; restart only if needed.
            if !session.isRunning { session.startRunning() }
            publish(id, "Resuming camera…")
        case AVCaptureSession.runtimeErrorNotification:
            tearDown()
            publish(id, "Camera error: \(error ?? "Capture stopped"). Choose Retry to reconnect.")
        case AVCaptureSession.didStopRunningNotification:
            publish(id, "Camera stopped. Choose Retry to reconnect.")
        default: break
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let id = activeID, session.isRunning, !interrupted else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastDetectionTime >= 0.2 else { return }
        lastDetectionTime = now
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Process this frame synchronously; never enqueue or retain a frame backlog.
        autoreleasepool {
            do {
                let request = VNDetectFaceRectanglesRequest()
                try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:]).perform([request])
                let count = request.results?.count ?? 0
                publish(id, count == 0 ? "No face detected" : (count == 1 ? "Face detected" : "\(count) faces detected"), count: count, streaming: true)
            } catch {
                publish(id, "Face detection unavailable. Choose Retry.", streaming: true)
            }
        }
    }

    private func publish(_ id: UUID, _ text: String, count: Int = 0, streaming: Bool = false, denied: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentationID == id else { return }
            self.message = text
            self.faceCount = count
            self.isStreaming = streaming
            self.permissionDenied = denied
        }
    }
}

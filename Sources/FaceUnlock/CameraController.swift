import AVFoundation
import Combine
import Vision
import RecognitionCore

/// Session configuration, capture callbacks, and Vision work share one serial queue.
/// Only published UI values and presentationID are accessed on the main thread.
final class CameraController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published private(set) var message = "Camera is stopped"
    @Published private(set) var faceCount = 0
    @Published private(set) var isStreaming = false
    @Published private(set) var permissionDenied = false

    @Published private(set) var completed = false
    @Published private(set) var candidate: EnrollmentProfile?

    @Published private(set) var diagnostics: EnrollmentDiagnostics?

    @Published private(set) var recognitionDiagnostics: RecognitionDiagnostics?

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.faceunlock.camera", qos: .userInitiated)
    private var presentationID: UUID?
    private var presentationCancellation: CaptureCancellation?
    private var activeCancellation: CaptureCancellation?
    private var activeID: UUID?
    private var observers: [NSObjectProtocol] = []
    private var lastDetectionTime = 0.0
    private var interrupted = false
    private var lastFrameTimestamp = -Double.infinity
    private var pipeline: RecognitionPipeline?

    override init() { super.init() }

    private func observeSession(_ id: UUID) {
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
                    guard let self, self.activeID == id else { return }
                    self.handle(name, isOurSession: isOurSession, deviceID: deviceID, error: error)
                }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Called only when the setup window opens or the user explicitly retries.
    func start(pipeline: RecognitionPipeline? = nil, timeout: TimeInterval = 90) {
        dispatchPrecondition(condition: .onQueue(.main))
        presentationCancellation?.cancel()
        let cancellation = CaptureCancellation()
        presentationCancellation = cancellation
        let id = UUID()
        presentationID = id
        completed = false
        candidate = nil
        diagnostics = nil
        recognitionDiagnostics = nil
        message = "Checking camera permission…"
        faceCount = 0
        isStreaming = false
        permissionDenied = false
        queue.async { [weak self] in
            guard let self, !cancellation.isCancelled else { return }
            self.tearDown()
            self.activeCancellation = cancellation
            self.activeID = id
            self.pipeline = pipeline
            self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.activeID == id else { return }
                self.activeID = nil
                self.tearDown()
                self.pipeline = nil
                self.publish(id, "Camera session timed out. Close or retry.", complete: true)
            }
            do {
                if let pipeline {
                    self.publish(id, "Loading local face model…")
                    try pipeline.prepare()
                }
            } catch {
                self.activeID = nil
                self.pipeline = nil
                self.publish(id, "Error: \(error.localizedDescription)", complete: true)
                return
            }
            guard !cancellation.isCancelled else { return }
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                self.configureAndStart(id)
            case .notDetermined:
                self.publish(id, "Waiting for camera permission…")
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    self?.queue.async { [weak self] in
                        guard let self, self.activeID == id else { return }
                        if granted { self.configureAndStart(id) }
                        else { self.fail(id, "Camera access denied. Allow FaceUnlock in System Settings → Privacy & Security → Camera.", denied: true) }
                    }
                }
            case .denied:
                self.fail(id, "Camera access denied. Allow FaceUnlock in System Settings → Privacy & Security → Camera.", denied: true)
            case .restricted:
                self.fail(id, "Camera access is restricted by macOS or device management.")
            @unknown default:
                self.fail(id, "Camera permission is unavailable on this system.")
            }
        }
    }

    func stop(wait: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        // Invalidates queued UI updates and permission replies before stopping capture.
        presentationCancellation?.cancel()
        presentationCancellation = nil
        presentationID = nil
        diagnostics = nil
        recognitionDiagnostics = nil
        candidate = nil
        completed = false
        faceCount = 0
        isStreaming = false
        message = "Camera is stopped"
        let work = { [self] in
            activeID = nil
            activeCancellation = nil
            pipeline = nil
            tearDown()
        }
        if wait { queue.sync(execute: work) }
        else { queue.async(execute: work) }
    }

    func report(_ text: String) {
        stop(wait: true)
        candidate = nil
        completed = true
        message = text
    }

    private func configureAndStart(_ id: UUID) {
        guard activeID == id, activeCancellation?.isCancelled == false else { return }
        guard let device = AVCaptureDevice.default(for: .video) else {
            fail(id, "No camera available. Connect a camera, then choose Retry.")
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
                fail(id, "Unable to use this camera. Close other camera apps, then retry.")
                return
            }
            session.addInput(input)
            guard session.canAddOutput(output) else {
                session.removeInput(input)
                session.commitConfiguration()
                fail(id, "Camera video output is unavailable.")
                return
            }
            session.addOutput(output)
            // Inference sees unmirrored sensor frames. Only the preview is mirrored.
            if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = CameraCoordinates.captureMirrored
            }
            session.commitConfiguration()
            lastDetectionTime = 0
            lastFrameTimestamp = -Double.infinity
            publish(id, "Starting camera…")
            observeSession(id)
            session.startRunning()
            if !session.isRunning {
                fail(id, "Camera could not start. Close other camera apps, then retry.")
            }
        } catch {
            fail(id, "Unable to open camera: \(error.localizedDescription)")
        }
    }

    private func tearDown() {
        // Remove observers before intentional stop; notifications queued by an older
        // run carry its UUID and cannot stop or alter a replacement capture session.
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
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
            fail(id, "Camera disconnected. Reconnect it, then choose Retry.")
            return
        }
        guard isOurSession else { return }
        pipeline?.interrupt()
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
            fail(id, "Camera error: \(error ?? "Capture stopped"). Choose Retry to reconnect.")
        case AVCaptureSession.didStopRunningNotification:
            if !interrupted { fail(id, "Camera stopped. Choose Retry to reconnect.") }
        default: break
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let id = activeID, activeCancellation?.isCancelled == false, session.isRunning, !interrupted else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard timestamp.isFinite, timestamp > lastFrameTimestamp else { return }
        lastFrameTimestamp = timestamp
        guard now - lastDetectionTime >= (pipeline == nil ? 0.2 : 0.5) else { return }
        lastDetectionTime = now
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Process this frame synchronously; never enqueue or retain a frame backlog.
        autoreleasepool {
            do {
                let detector = VNDetectFaceRectanglesRequest()
                detector.revision = VNDetectFaceRectanglesRequestRevision3
                let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: CameraCoordinates.visionOrientation, options: [:])
                try handler.perform([detector])
                let request = VNDetectFaceLandmarksRequest()
                request.inputFaceObservations = detector.results
                try handler.perform([request])
                let count = request.results?.count ?? 0
                if let pipeline {
                    let quality = VNDetectFaceCaptureQualityRequest()
                    quality.inputFaceObservations = request.results
                    try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: CameraCoordinates.visionOrientation, options: [:]).perform([quality])
                    let detected = detector.results ?? []
                    let pose = detected.count == 1 ? detected.first.map {
                        FacePose(yaw: $0.yaw?.doubleValue, pitch: $0.pitch?.doubleValue, roll: $0.roll?.doubleValue)
                    } : nil
                    let result = pipeline.process(buffer, faces: detected.count == 1 ? (request.results ?? []) : detected,
                        quality: quality.results?.first?.faceCaptureQuality, timestamp: now, detectorPose: pose, frameTimestamp: timestamp)
                    if result.complete {
                        activeID = nil
                        self.pipeline = nil
                        tearDown()
                    }
                    publish(id, result.text, count: count, streaming: !result.complete, complete: result.complete, candidate: result.candidate, diagnostics: result.diagnostics, recognitionDiagnostics: result.recognitionDiagnostics)
                    return
                }
                publish(id, count == 0 ? "No face detected" : (count == 1 ? "Face detected" : "\(count) faces detected"), count: count, streaming: true)
            } catch {
                activeID = nil
                pipeline = nil
                tearDown()
                publish(id, "Error: face analysis unavailable. Close and retry.", complete: true)
            }
        }
    }

    private func fail(_ id: UUID, _ text: String, denied: Bool = false) {
        guard activeID == id else { return }
        activeID = nil
        pipeline = nil
        tearDown()
        publish(id, text, denied: denied, complete: true)
    }

    private func publish(_ id: UUID, _ text: String, count: Int = 0, streaming: Bool = false, denied: Bool = false, complete: Bool = false, candidate: EnrollmentProfile? = nil, diagnostics: EnrollmentDiagnostics? = nil, recognitionDiagnostics: RecognitionDiagnostics? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentationID == id else { return }
            self.message = text
            self.faceCount = count
            self.isStreaming = streaming
            self.permissionDenied = denied
            self.completed = complete
            self.candidate = candidate
            if let diagnostics { self.diagnostics = diagnostics }
            self.recognitionDiagnostics = CommandLine.arguments.contains("--recognition-diagnostics") ? recognitionDiagnostics : nil
        }
    }
}

/// Closing invalidates a pending permission/model-load request immediately, even
/// while the serial capture queue is busy. Mutable state is protected by a lock.
private final class CaptureCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

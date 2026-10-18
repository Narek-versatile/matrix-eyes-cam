import AVFoundation
import CoreVideo
import Metal

/// Streams the built-in camera into Metal textures with zero copies.
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "matrix-eyes.camera")
    private var cache: CVMetalTextureCache?
    private let lock = NSLock()
    private var latestTexture: MTLTexture?
    private var latestRef: CVMetalTexture?

    /// Called on the main queue with a message to show the user when the camera can't be used.
    var onProblem: ((String) -> Void)?
    /// Called on the camera queue with every new frame (used to feed depth estimation).
    var onPixelBuffer: ((CVPixelBuffer) -> Void)?

    func start(device: MTLDevice) {
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            queue.async { self.configure() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    self.queue.async { self.configure() }
                } else {
                    self.report(Camera.deniedMessage)
                }
            }
        default:
            report(Camera.deniedMessage)
        }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }

    /// Stops capturing (the camera light goes off); the last frame stays available.
    func pause() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func resume() {
        queue.async {
            if !self.session.isRunning && !self.session.inputs.isEmpty { self.session.startRunning() }
        }
    }

    /// Newest frame, plus the CoreVideo wrapper that must outlive the GPU's use of the texture.
    func latest() -> (MTLTexture, AnyObject?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let tex = latestTexture else { return nil }
        return (tex, latestRef)
    }

    private static let deniedMessage =
        "Camera access is off. Turn it on in System Settings › Privacy & Security › Camera › Matrix Eyes, then reopen the app."

    private func report(_ message: String) {
        DispatchQueue.main.async { self.onProblem?(message) }
    }

    private func configure() {
        let builtIn = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera],
                                                       mediaType: .video, position: .unspecified).devices.first
        guard let device = builtIn ?? AVCaptureDevice.default(for: .video) else {
            report("No camera found.")
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                report("The camera is busy in another app.")
                return
            }
            session.addInput(input)

            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                report("Couldn't read frames from the camera.")
                return
            }
            session.addOutput(output)
            session.commitConfiguration()
            session.startRunning()
        } catch {
            report("Couldn't open the camera: \(error.localizedDescription)")
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer), let cache else { return }
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        var ref: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil,
                                                        .bgra8Unorm, w, h, 0, &ref) == kCVReturnSuccess,
              let ref, let tex = CVMetalTextureGetTexture(ref) else { return }
        lock.lock()
        latestTexture = tex
        latestRef = ref
        lock.unlock()
        onPixelBuffer?(pixelBuffer)
    }
}

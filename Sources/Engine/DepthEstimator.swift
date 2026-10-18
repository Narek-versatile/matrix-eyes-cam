import CoreML
import CoreVideo
import Metal
import QuartzCore
import Vision

/// Runs Apple's Depth Anything V2 (Core ML) on camera frames in the background, on the
/// Neural Engine, so the GPU stays free for rendering. Output is relative inverse depth
/// (larger = nearer) as an r16Float texture.
final class DepthEstimator {
    enum LoadError: Error { case modelMissing }

    private let request: VNCoreMLRequest
    private let device: MTLDevice
    private let queue = DispatchQueue(label: "matrix-eyes.depth", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var latest: MTLTexture?
    private(set) var lastInferenceMs: Double = 0

    init(device: MTLDevice) throws {
        guard let url = Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc") else {
            throw LoadError.modelMissing
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let model = try MLModel(contentsOf: url, configuration: config)
        request = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
        request.imageCropAndScaleOption = .scaleFill
        self.device = device
    }

    func latestTexture() -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// Non-blocking; drops the frame if the previous one is still being processed.
    func submit(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        if busy {
            lock.unlock()
            return
        }
        busy = true
        lock.unlock()
        queue.async {
            let tex = self.run(VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up))
            self.lock.lock()
            if let tex { self.latest = tex }
            self.busy = false
            self.lock.unlock()
        }
    }

    /// Synchronous variant for still images (render tests).
    func estimate(_ image: CGImage) -> MTLTexture? {
        run(VNImageRequestHandler(cgImage: image, orientation: .up))
    }

    private func run(_ handler: VNImageRequestHandler) -> MTLTexture? {
        let start = CACurrentMediaTime()
        guard (try? handler.perform([request])) != nil,
              let pb = (request.results?.first as? VNPixelBufferObservation)?.pixelBuffer,
              CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_OneComponent16Half
        else { return nil }

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                    withBytes: base, bytesPerRow: CVPixelBufferGetBytesPerRow(pb))
        lastInferenceMs = (CACurrentMediaTime() - start) * 1000
        return tex
    }
}

import CoreVideo
import Metal
import QuartzCore
import Vision

/// Cuts the person out of each camera frame (Vision person segmentation, in the background),
/// so the "space" background can replace everything that isn't you.
/// Output is an r8 mask the size of Vision's result: 1 = person.
final class PersonMasker {
    private let request = VNGeneratePersonSegmentationRequest()
    private let device: MTLDevice
    private let queue = DispatchQueue(label: "matrix-eyes.mask", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var latest: MTLTexture?
    private(set) var lastInferenceMs: Double = 0

    init(device: MTLDevice) {
        self.device = device
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
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
              CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_OneComponent8
        else { return nil }

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                    withBytes: base, bytesPerRow: CVPixelBufferGetBytesPerRow(pb))
        lastInferenceMs = (CACurrentMediaTime() - start) * 1000
        return tex
    }
}

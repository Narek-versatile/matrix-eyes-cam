import AVFoundation
import CoreVideo
import Metal
import MetalKit

/// An image or a looping video, as a Metal texture, for the "fill" silhouette.
final class MediaSource {
    let url: URL
    private let device: MTLDevice
    private var image: MTLTexture?
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var output: AVPlayerItemVideoOutput?
    private var cache: CVMetalTextureCache?
    private var lastFrame: (MTLTexture, CVMetalTexture)?

    static let videoTypes: Set<String> = ["mov", "mp4", "m4v"]

    init?(url: URL, device: MTLDevice) {
        self.url = url
        self.device = device
        if MediaSource.videoTypes.contains(url.pathExtension.lowercased()) {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            let item = AVPlayerItem(url: url)
            let queuePlayer = AVQueuePlayer()
            queuePlayer.isMuted = true
            looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
            // The looper plays copies of the template item; each copy needs its own video output.
            for copy in looper?.loopingPlayerItems ?? [] {
                copy.add(AVPlayerItemVideoOutput(pixelBufferAttributes: attributes))
            }
            player = queuePlayer
            output = nil
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
            queuePlayer.play()
        } else {
            let loader = MTKTextureLoader(device: device)
            guard let tex = try? loader.newTexture(URL: url, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft]) else {
                return nil
            }
            image = tex
        }
    }

    deinit { player?.pause() }

    /// The current picture (for a video: the newest frame).
    func currentTexture() -> MTLTexture? {
        if let image { return image }
        guard let player, let cache, let item = player.currentItem else { return lastFrame?.0 }
        let out = (item.outputs.first as? AVPlayerItemVideoOutput) ?? output
        guard let out else { return lastFrame?.0 }
        let time = out.itemTime(forHostTime: CACurrentMediaTime())
        if out.hasNewPixelBuffer(forItemTime: time), let pb = out.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            var ref: CVMetalTexture?
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            if CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, .bgra8Unorm, w, h, 0, &ref) == kCVReturnSuccess,
               let ref, let tex = CVMetalTextureGetTexture(ref) {
                lastFrame = (tex, ref)
            }
        }
        return lastFrame?.0
    }
}

import CoreGraphics
import Foundation
import Metal
import MetalKit
import QuartzCore

/// Mirrors `Uniforms` in Shaders.metal (shared with Matrix Eyes); keep the field order identical.
struct Uniforms {
    var resX: Float = 0, resY: Float = 0, time: Float = 0
    var cellH: Float = 24, cellAspect: Float = 0.8
    var exposure: Float = 1, contrast: Float = 1.35, speed: Float = 1
    var transT: Float = 100, transDir: Float = 1, camFade: Float = 0
    var camScaleX: Float = 1, camScaleY: Float = 1, mirror: Float = 0
    var glyphCount: Float = 0, atlasCols: Float = 0, atlasRows: Float = 0
    var smoothing: Float = 0.45, lumW: Float = 0, lumH: Float = 0
    var tanX: Float = 0.70, camAspect: Float = 16.0 / 9.0, zNear: Float = 0.45, zFar: Float = 5.0
    var zRef: Float = 0.75, gamma: Float = 0.45, cellQ: Float = 0.01, depthFade: Float = 0
    var depthAlpha: Float = 0.3, deadband: Float = 0.012, fogK: Float = 0.25
    var baseR: Float = 0.40, baseG: Float = 1.0, baseB: Float = 0.46
    var hotR: Float = 0.92, hotG: Float = 1.0, hotB: Float = 0.94
    var style: Float = 0, spaceOn: Float = 0, bhOn: Float = 0, maskOn: Float = 0
    var bhX: Float = 0.73, bhY: Float = 0.27, bhTanV: Float = 0.69, bhElev: Float = 0.13
    var matrixLook: Float = 1
}

/// Mirrors `CamParams` in Cam.metal.
struct CamParams {
    var time: Float = 0
    var bgKind: Float = 0, bgSpeed: Float = 1, bgBlackHole: Float = 1, bgDim: Float = 0.7
    var subjMode: Float = 0, effect: Float = 1, grade: Float = 0, material: Float = 1, fill: Float = 1
    var accentR: Float = 0.35, accentG: Float = 0.85, accentB: Float = 1
    var strength: Float = 0.7, keepFeatures: Float = 0.55, lightWrap: Float = 0.45
    var maskOn: Float = 0, hasMedia: Float = 0, mediaAspect: Float = 16.0 / 9.0, trailDecay: Float = 0.9
}

struct PreviewParams {
    var mirror: Float = 1, scaleX: Float = 1, scaleY: Float = 1, pad: Float = 0
}

enum EngineError: Error, CustomStringConvertible {
    case shadersMissing
    case missingFunction(String)
    var description: String {
        switch self {
        case .shadersMissing: return "The shader files were not found in the app bundle."
        case .missingFunction(let n): return "Shader function \(n) is missing."
        }
    }
}

/// Turns camera frames into finished call frames: background + your silhouette, at the output size.
final class Engine {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let width: Int, height: Int

    var cameraFrame: (() -> (MTLTexture, AnyObject?)?)?
    var depthFrame: (() -> MTLTexture?)?
    var maskFrame: (() -> MTLTexture?)?
    var media: MediaSource?
    /// Called with every finished frame inside its command buffer (before commit), e.g. to copy
    /// it into the virtual camera's pixel buffer.
    var onFrame: ((MTLTexture, MTLCommandBuffer) -> Void)?

    /// The newest finished frame (BGRA, unmirrored).
    private(set) var latestOutput: MTLTexture?
    var outputFormat: MTLPixelFormat { .bgra8Unorm }

    private let lock = NSLock()
    private var _preset: Preset
    var preset: Preset {
        get { lock.lock(); defer { lock.unlock() }; return _preset }
        set { lock.lock(); _preset = newValue; lock.unlock() }
    }

    private let lumPSO, depthPSO, geoPSO, maskPSO, roomDownPSO, blurPSO, downPSO: MTLRenderPipelineState
    private let backgroundPSO, subjectPSO, trailPSO, compositePSO: MTLRenderPipelineState
    let previewPipeline: (MTLPixelFormat) throws -> MTLRenderPipelineState
    let sampler: MTLSamplerState
    private let glyphSampler: MTLSamplerState
    private let atlas: GlyphAtlas
    private let black: MTLTexture
    private let flatGeo: MTLTexture

    private var lumTex: [MTLTexture] = [], lumIndex = 0
    private var depthSmooth: [MTLTexture] = [], depthIndex = 0, depthSize = (0, 0)
    private var geoTex: MTLTexture?
    private var maskSmooth: [MTLTexture] = [], maskIndex = 0, maskSize = (0, 0)
    private let roomA, roomB, bgTex, bgSoftA, bgSoftB, subjectTex: MTLTexture
    private var trail: [MTLTexture], trailIndex = 0
    private var outputs: [MTLTexture], outputIndex = 0

    private let clockStart = CACurrentMediaTime()
    private var cameraStart: Double?
    private var depthProgress: Double = 0
    private var lastTime: Double?

    init(device: MTLDevice, width: Int = 1280, height: Int = 720, preset: Preset) throws {
        self.device = device
        self.width = width
        self.height = height
        _preset = preset
        queue = device.makeCommandQueue()!

        guard let source = Engine.shaderSource() else { throw EngineError.shadersMissing }
        let library = try device.makeLibrary(source: source, options: nil)
        func pipeline(_ fragment: String, _ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            guard let vs = library.makeFunction(name: "fullscreenVS") else { throw EngineError.missingFunction("fullscreenVS") }
            guard let fs = library.makeFunction(name: fragment) else { throw EngineError.missingFunction(fragment) }
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vs
            d.fragmentFunction = fs
            d.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: d)
        }
        lumPSO = try pipeline("lumFS", .r16Float)
        depthPSO = try pipeline("depthFS", .r32Float)
        geoPSO = try pipeline("geoFS", .rgba16Float)
        maskPSO = try pipeline("maskFS", .r16Float)
        roomDownPSO = try pipeline("camRoomDownFS", .rgba16Float)
        blurPSO = try pipeline("blurFS", .rgba16Float)
        downPSO = try pipeline("downFS", .rgba16Float)
        backgroundPSO = try pipeline("camBackgroundFS", .rgba16Float)
        subjectPSO = try pipeline("camSubjectFS", .rgba16Float)
        trailPSO = try pipeline("camTrailFS", .rgba16Float)
        compositePSO = try pipeline("camCompositeFS", .bgra8Unorm)
        previewPipeline = { format in try pipeline("camPreviewFS", format) }

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)!
        sd.maxAnisotropy = 8
        glyphSampler = device.makeSamplerState(descriptor: sd)!
        atlas = GlyphAtlas(device: device, queue: queue)

        let bd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        black = device.makeTexture(descriptor: bd)!
        var px: UInt32 = 0xFF00_0000
        black.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
        let gd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        flatGeo = device.makeTexture(descriptor: gd)!
        var flat: [Float16] = [0.75, 0, 0, 0]
        flatGeo.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &flat, bytesPerRow: 8)

        func tex(_ w: Int, _ h: Int, _ f: MTLPixelFormat, mip: Bool = false, storage: MTLStorageMode = .private) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: max(w, 1), height: max(h, 1), mipmapped: mip)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = storage
            return device.makeTexture(descriptor: d)!
        }
        lumTex = (0..<2).map { _ in tex(width / 4, height / 4, .r16Float, mip: true) }
        roomA = tex(width / 4, height / 4, .rgba16Float)
        roomB = tex(width / 4, height / 4, .rgba16Float)
        bgTex = tex(width, height, .rgba16Float)
        bgSoftA = tex(width / 4, height / 4, .rgba16Float)
        bgSoftB = tex(width / 4, height / 4, .rgba16Float)
        subjectTex = tex(width, height, .rgba16Float)
        trail = (0..<2).map { _ in tex(width, height, .rgba16Float) }
        outputs = (0..<3).map { _ in tex(width, height, .bgra8Unorm, storage: .shared) }
        clear(lumTex, 0.3)
        clear(trail, 0)
    }

    /// Shader files are concatenated in this order; later ones use helpers from earlier ones.
    private static func shaderSource() -> String? {
        let names = ["Shaders", "Space", "Materials", "Cam"]
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let devDirs = [
            exe.deletingLastPathComponent().appendingPathComponent("../Resources"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Shaders"),
        ]
        var parts: [String] = []
        for name in names {
            // ".msl": Metal source kept as text (the pieces only compile once concatenated)
            let url = Bundle.main.url(forResource: name, withExtension: "msl")
                ?? devDirs.map { $0.appendingPathComponent("\(name).msl") }.first { FileManager.default.fileExists(atPath: $0.path) }
            guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            parts.append(text)
        }
        return parts.joined(separator: "\n")
    }

    var now: Double { CACurrentMediaTime() - clockStart }

    /// Renders one call frame. Returns the command buffer (already committed).
    @discardableResult
    func renderFrame(time: Double? = nil) -> MTLCommandBuffer? {
        let t = time ?? now
        let p = preset
        guard let cmd = queue.makeCommandBuffer() else { return nil }

        var cam = black
        if let frame = cameraFrame?() {
            cam = frame.0
            if cameraStart == nil { cameraStart = t }
            if let keep = frame.1 { cmd.addCompletedHandler { _ in withExtendedLifetime(keep) {} } }
        }
        let dt = lastTime.map { min(max(t - $0, 0), 0.1) } ?? 0
        lastTime = t

        var u = Uniforms()
        u.resX = Float(width)
        u.resY = Float(height)
        u.time = Float(t)
        u.cellH = Float(height) / 72
        u.mirror = 0                                    // calls get the true, unmirrored picture
        if let t0 = cameraStart {
            let x = min(max((t - t0 - 0.2) / 0.8, 0), 1)
            u.camFade = Float(x * x * (3 - 2 * x))
        }
        let outAspect = Float(width) / Float(height)
        let camAspect = Float(cam.width) / Float(cam.height)
        if outAspect > camAspect {
            u.camScaleX = 1
            u.camScaleY = camAspect / outAspect
        } else {
            u.camScaleX = outAspect / camAspect
            u.camScaleY = 1
        }
        u.camAspect = camAspect
        u.glyphCount = Float(atlas.count)
        u.atlasCols = Float(atlas.cols)
        u.atlasRows = Float(atlas.rows)
        u.cellQ = 2 * u.zRef * (u.tanX / camAspect) * u.camScaleY / 72

        let depthRaw = p.needsDepth ? depthFrame?() : nil
        depthProgress = min(max(depthProgress + (depthRaw != nil ? dt : -dt) / 1.0, 0), 1)
        u.depthFade = Float(depthProgress * depthProgress * (3 - 2 * depthProgress))
        let maskRaw = maskFrame?()
        u.maskOn = maskRaw != nil ? 1 : 0
        u.bhOn = p.background == .space && p.blackHole ? 1 : 0

        let lum = lumTex[lumIndex], prevLum = lumTex[1 - lumIndex]
        lumIndex = 1 - lumIndex
        u.lumW = Float(lum.width)
        u.lumH = Float(lum.height)

        var cp = CamParams()
        cp.time = Float(t)
        cp.bgKind = Float(p.background.rawValue)
        cp.bgSpeed = Float(p.backgroundSpeed)
        cp.bgBlackHole = p.blackHole ? 1 : 0
        cp.bgDim = Float(p.tidyAmount)
        cp.subjMode = Float(p.subject.rawValue)
        cp.effect = Float(p.effect.rawValue)
        cp.grade = Float(p.grade.rawValue)
        cp.material = Float(p.material.rawValue)
        cp.fill = Float(p.fill.rawValue)
        let accent = p.accent + [1, 1, 1]
        (cp.accentR, cp.accentG, cp.accentB) = (Float(accent[0]), Float(accent[1]), Float(accent[2]))
        cp.strength = Float(p.strength)
        cp.keepFeatures = Float(p.keepFeatures)
        cp.lightWrap = Float(p.lightWrap)
        cp.maskOn = u.maskOn
        var mediaTex = black
        if p.subject == .fill && p.fill == .media, let m = media?.currentTexture() {
            mediaTex = m
            cp.hasMedia = 1
            cp.mediaAspect = Float(m.width) / Float(m.height)
        }

        // 1. luminance (with mipmaps)
        pass(cmd, lum, lumPSO) { e in
            e.setFragmentTexture(cam, index: 0)
            e.setFragmentTexture(prevLum, index: 1)
            e.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        }
        if let blit = cmd.makeBlitCommandEncoder() { blit.generateMipmaps(for: lum); blit.endEncoding() }

        // 2. depth -> geometry, only for looks that shade your 3D shape
        var geometry = flatGeo
        if let depthRaw {
            ensureDepth(depthRaw.width, depthRaw.height)
            let smooth = depthSmooth[depthIndex], prev = depthSmooth[1 - depthIndex]
            depthIndex = 1 - depthIndex
            pass(cmd, smooth, depthPSO) { e in
                e.setFragmentTexture(depthRaw, index: 0)
                e.setFragmentTexture(prev, index: 1)
                e.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            }
            if let geoTex {
                pass(cmd, geoTex, geoPSO) { e in
                    e.setFragmentTexture(smooth, index: 0)
                    e.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                }
                geometry = geoTex
            }
        } else if depthProgress > 0, let geoTex {
            geometry = geoTex
        }

        // 3. the person cut-out, smoothed over time
        var maskTex = black
        if let maskRaw {
            ensureMask(maskRaw.width, maskRaw.height)
            let smooth = maskSmooth[maskIndex], prev = maskSmooth[1 - maskIndex]
            maskIndex = 1 - maskIndex
            pass(cmd, smooth, maskPSO) { e in
                e.setFragmentTexture(maskRaw, index: 0)
                e.setFragmentTexture(prev, index: 1)
            }
            maskTex = smooth
        }

        // 4. your room with you removed, blurred (for the blurred / tidy backgrounds)
        if p.background == .blurred || p.background == .tidy {
            pass(cmd, roomA, roomDownPSO) { e in
                e.setFragmentTexture(cam, index: 0)
                e.setFragmentTexture(maskTex, index: 1)
                e.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                e.setFragmentBytes(&cp, length: MemoryLayout<CamParams>.stride, index: 1)
            }
            let spreads: [Float] = p.background == .blurred ? [1.5, 3.0, 5.0] : [1.5, 3.0]
            for spread in spreads {
                blur(cmd, roomA, roomB, SIMD2(1, 0), spread)
                blur(cmd, roomB, roomA, SIMD2(0, 1), spread)
            }
        }

        // 5. background
        pass(cmd, bgTex, backgroundPSO) { e in
            e.setFragmentTexture(cam, index: 0)
            e.setFragmentTexture(self.roomA, index: 1)
            e.setFragmentTexture(lum, index: 2)
            e.setFragmentTexture(self.atlas.texture, index: 3)
            e.setFragmentTexture(geometry, index: 4)
            e.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            e.setFragmentBytes(&cp, length: MemoryLayout<CamParams>.stride, index: 1)
        }
        // soft copy of the background, for light wrapping onto your edges
        var texel = SIMD2<Float>(1 / Float(width), 1 / Float(height))
        pass(cmd, bgSoftA, downPSO) { e in
            e.setFragmentTexture(self.bgTex, index: 0)
            e.setFragmentBytes(&texel, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        }
        blur(cmd, bgSoftA, bgSoftB, SIMD2(1, 0), 2)
        blur(cmd, bgSoftB, bgSoftA, SIMD2(0, 1), 2)

        // 6. your silhouette
        pass(cmd, subjectTex, subjectPSO) { e in
            e.setFragmentTexture(cam, index: 0)
            e.setFragmentTexture(maskTex, index: 1)
            e.setFragmentTexture(lum, index: 2)
            e.setFragmentTexture(self.atlas.texture, index: 3)
            e.setFragmentTexture(geometry, index: 4)
            e.setFragmentTexture(mediaTex, index: 5)
            e.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            e.setFragmentBytes(&cp, length: MemoryLayout<CamParams>.stride, index: 1)
        }

        // 7. ghost trails
        let trailNow = trail[trailIndex], trailPrev = trail[1 - trailIndex]
        trailIndex = 1 - trailIndex
        pass(cmd, trailNow, trailPSO) { e in
            e.setFragmentTexture(trailPrev, index: 0)
            e.setFragmentTexture(self.subjectTex, index: 1)
            e.setFragmentBytes(&cp, length: MemoryLayout<CamParams>.stride, index: 1)
        }

        // 8. composite
        let out = outputs[outputIndex]
        outputIndex = (outputIndex + 1) % outputs.count
        pass(cmd, out, compositePSO) { e in
            e.setFragmentTexture(self.bgTex, index: 0)
            e.setFragmentTexture(self.subjectTex, index: 1)
            e.setFragmentTexture(trailNow, index: 2)
            e.setFragmentTexture(self.bgSoftA, index: 3)
            e.setFragmentBytes(&cp, length: MemoryLayout<CamParams>.stride, index: 1)
        }
        onFrame?(out, cmd)
        cmd.addCompletedHandler { [weak self] _ in self?.publish(out) }
        cmd.commit()
        return cmd
    }

    private func publish(_ tex: MTLTexture) {
        lock.lock()
        latestOutput = tex
        lock.unlock()
    }

    func latest() -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        return latestOutput
    }

    // MARK: - Helpers

    private func pass(_ cmd: MTLCommandBuffer, _ target: MTLTexture, _ pso: MTLRenderPipelineState,
                      _ bind: (MTLRenderCommandEncoder) -> Void) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let e = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        e.setRenderPipelineState(pso)
        e.setFragmentSamplerState(sampler, index: 0)
        e.setFragmentSamplerState(glyphSampler, index: 1)
        bind(e)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
    }

    private func blur(_ cmd: MTLCommandBuffer, _ src: MTLTexture, _ dst: MTLTexture, _ dir: SIMD2<Float>, _ spread: Float) {
        var d = dir * spread / SIMD2(Float(src.width), Float(src.height))
        pass(cmd, dst, blurPSO) { e in
            e.setFragmentTexture(src, index: 0)
            e.setFragmentBytes(&d, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        }
    }

    private func ensureDepth(_ w: Int, _ h: Int) {
        guard depthSize != (w, h) else { return }
        depthSize = (w, h)
        depthSmooth = (0..<2).map { _ in makeTexture(w, h, .r32Float) }
        clear(depthSmooth, 0)
        geoTex = makeTexture(w, h, .rgba16Float)
    }

    private func ensureMask(_ w: Int, _ h: Int) {
        guard maskSize != (w, h) else { return }
        maskSize = (w, h)
        maskSmooth = (0..<2).map { _ in makeTexture(w, h, .r16Float) }
        clear(maskSmooth, 0)
    }

    func makeTexture(_ w: Int, _ h: Int, _ f: MTLPixelFormat, storage: MTLStorageMode = .private) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = storage
        return device.makeTexture(descriptor: d)!
    }

    /// Fresh GPU memory is undefined; buffers that feed back into themselves start cleared.
    private func clear(_ textures: [MTLTexture], _ value: Double) {
        guard let cmd = queue.makeCommandBuffer() else { return }
        for t in textures {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = t
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].clearColor = MTLClearColor(red: value, green: 0, blue: 0, alpha: value)
            rp.colorAttachments[0].storeAction = .store
            cmd.makeRenderCommandEncoder(descriptor: rp)?.endEncoding()
        }
        cmd.commit()
    }

    static func image(from tex: MTLTexture) -> CGImage? {
        let w = tex.width, h = tex.height, bpr = w * 4
        var bytes = [UInt8](repeating: 0, count: bpr * h)
        tex.getBytes(&bytes, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

import CoreGraphics
import Foundation
import Metal
import MetalKit
import QuartzCore

// Shared by Matrix Eyes and Matrix Eyes Cam (synced by scripts/sync-to-matrix-eyes.sh).

/// Mirrors `Uniforms` in Shaders.msl; keep the field order identical.
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
    var bhDist: Float = 25
}

/// Mirrors `CamParams` in Cam.msl.
struct CamParams {
    var time: Float = 0
    var bgKind: Float = 0, bgSpeed: Float = 1, bgBlackHole: Float = 1, bgDim: Float = 0.7
    var subjMode: Float = 0, effect: Float = 1, grade: Float = 0, material: Float = 1, fill: Float = 1
    var accentR: Float = 0.35, accentG: Float = 0.85, accentB: Float = 1
    var strength: Float = 0.7, keepFeatures: Float = 0.55, lightWrap: Float = 0.45
    var maskOn: Float = 0, hasMedia: Float = 0, mediaAspect: Float = 16.0 / 9.0, trailDecay: Float = 0.9
    var holeOn: Float = 0, holeX: Float = 0.73, holeY: Float = 0.27
    var holeBend: Float = 0, holePull: Float = 0, holeLight: Float = 0
    var glow: Float = 0, fade: Float = 1, vignette: Float = 0.25
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

/// Turns camera frames into finished pictures: a background, what your silhouette becomes, the
/// black hole and how it treats you, glow, and the wipe in/out of the look.
final class Engine {
    let device: MTLDevice
    let queue: MTLCommandQueue
    private(set) var width: Int
    private(set) var height: Int

    var cameraFrame: (() -> (MTLTexture, AnyObject?)?)?
    var depthFrame: (() -> MTLTexture?)?
    var maskFrame: (() -> MTLTexture?)?
    /// Your face in camera-image coordinates (0...1, top-left origin), for the orbiting hole.
    var faceRect: (() -> CGRect?)?
    var media: MediaSource?
    /// Matrix Eyes shows a mirrored picture; Matrix Eyes Cam sends the true one (and mirrors only its preview).
    var mirrorsPicture = false
    /// Called with every finished frame inside its command buffer (before commit).
    var onFrame: ((MTLTexture, MTLCommandBuffer) -> Void)?

    private let lock = NSLock()
    private var _preset: Preset
    private var latestOutput: MTLTexture?

    private let lumPSO, depthPSO, geoPSO, maskPSO, roomDownPSO, blurPSO, brightPSO: MTLRenderPipelineState
    private let backgroundPSO, subjectPSO, trailPSO, compositePSO, finalPSO: MTLRenderPipelineState
    let previewPipeline: (MTLPixelFormat) throws -> MTLRenderPipelineState
    let sampler: MTLSamplerState
    private let glyphSampler: MTLSamplerState
    private let atlas: GlyphAtlas
    private let black: MTLTexture
    private let transparent: MTLTexture
    private let flatGeo: MTLTexture

    // per-size resources
    private var lumTex: [MTLTexture] = [], lumIndex = 0
    private var roomA: MTLTexture!, roomB: MTLTexture!
    private var bgFull: MTLTexture!, bgHalf: MTLTexture!
    private var bgSoftA: MTLTexture!, bgSoftB: MTLTexture!
    private var subjectTex: MTLTexture!, compTex: MTLTexture!
    private var glowA: MTLTexture!, glowB: MTLTexture!, glowC: MTLTexture!, glowD: MTLTexture!
    private var trail: [MTLTexture] = [], trailIndex = 0, trailsLive = false
    private var outputs: [MTLTexture] = [], outputIndex = 0
    private var depthSmooth: [MTLTexture] = [], depthIndex = 0, depthSize = (0, 0)
    private var geoTex: MTLTexture?
    private var maskSmooth: [MTLTexture] = [], maskIndex = 0, maskSize = (0, 0)

    private let clockStart = CACurrentMediaTime()
    private var cameraStart: Double?
    private var depthProgress: Double = 0
    private var lastTime: Double?
    private var smoothedHead: SIMD2<Double>?

    // wipe (Matrix Eyes' Space key) and look cross-fade
    private(set) var lookOn = true
    private var wipeStart: Double = -100
    private var fadeOut: Double = 0, fadeIn: Double = 1
    private var pendingPreset: Preset?

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
        brightPSO = try pipeline("camBrightFS", .rgba16Float)
        backgroundPSO = try pipeline("camBackgroundFS", .rgba16Float)
        subjectPSO = try pipeline("camSubjectFS", .rgba16Float)
        trailPSO = try pipeline("camTrailFS", .rgba16Float)
        compositePSO = try pipeline("camCompositeFS", .rgba16Float)
        finalPSO = try pipeline("camFinalFS", .bgra8Unorm)
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
        transparent = device.makeTexture(descriptor: bd)!
        var none: UInt32 = 0
        transparent.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &none, bytesPerRow: 4)
        let gd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        flatGeo = device.makeTexture(descriptor: gd)!
        var flat: [Float16] = [0.75, 0, 0, 0]
        flatGeo.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &flat, bytesPerRow: 8)
        buildSizedResources()
    }

    // MARK: - Settings

    /// The look being shown. Setting it from the UI cross-fades through black when the change is
    /// big (another background or silhouette); small adjustments apply at once.
    var preset: Preset {
        get { lock.lock(); defer { lock.unlock() }; return pendingPreset ?? _preset }
        set { setPreset(newValue, animated: false) }
    }

    func setPreset(_ p: Preset, animated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let current = pendingPreset ?? _preset
        let big = p.background != current.background || p.subject != current.subject || p.material != current.material
            || p.effect != current.effect || p.fill != current.fill || p.matrixTheme != current.matrixTheme
        if animated && big {
            pendingPreset = p
            fadeOut = 0
        } else {
            _preset = p
            pendingPreset = nil
        }
    }

    /// Wipes the look away to the plain camera, or back (Matrix Eyes' Space key).
    func toggleLook() {
        lookOn.toggle()
        wipeStart = now
    }

    func setOutputSize(_ w: Int, _ h: Int) {
        guard w > 0, h > 0, w != width || h != height else { return }
        width = w
        height = h
        buildSizedResources()
    }

    func latest() -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        return latestOutput
    }

    var now: Double { CACurrentMediaTime() - clockStart }

    /// Where the black hole is on screen right now (as the picture is shown), 0...1.
    private(set) var holePosition = SIMD2<Double>(0.73, 0.27)

    // MARK: - Frame

    /// Renders one picture. Returns the command buffer (already committed).
    @discardableResult
    /// `then` can encode more work on the finished picture in the same command buffer (Matrix Eyes
    /// draws it into the window this way).
    func renderFrame(time: Double? = nil, then: ((MTLTexture, MTLCommandBuffer) -> Void)? = nil) -> MTLCommandBuffer? {
        let t = time ?? now
        let dt = lastTime.map { min(max(t - $0, 0), 0.1) } ?? 0
        lastTime = t

        // cross-fade bookkeeping
        var fade = 1.0
        lock.lock()
        if let next = pendingPreset {
            fadeOut += dt
            fade = max(1 - fadeOut / 0.14, 0)
            if fadeOut >= 0.14 {
                _preset = next
                pendingPreset = nil
                fadeIn = 0
            }
        } else if fadeIn < 0.3 {
            fadeIn += dt
            let x = min(fadeIn / 0.3, 1)
            fade = x * x * (3 - 2 * x)
        }
        let p = _preset
        lock.unlock()

        guard let cmd = queue.makeCommandBuffer() else { return nil }
        var cam = black
        if let frame = cameraFrame?() {
            cam = frame.0
            if cameraStart == nil { cameraStart = t }
            if let keep = frame.1 { cmd.addCompletedHandler { _ in withExtendedLifetime(keep) {} } }
        }

        let mirror = mirrorsPicture && p.mirror
        var u = Uniforms()
        u.resX = Float(width)
        u.resY = Float(height)
        u.time = Float(t)
        u.cellH = Float(height) / Float(p.glyphRows)
        u.exposure = Float(p.brightness)
        u.speed = Float(p.rainSpeed)
        u.mirror = mirror ? 1 : 0
        u.transT = Float(t - wipeStart)
        u.transDir = lookOn ? 1 : 0
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
        u.cellQ = 2 * u.zRef * (u.tanX / camAspect) * u.camScaleY / Float(p.glyphRows)
        (u.baseR, u.baseG, u.baseB) = (p.matrixTheme.base.x, p.matrixTheme.base.y, p.matrixTheme.base.z)
        (u.hotR, u.hotG, u.hotB) = (p.matrixTheme.hot.x, p.matrixTheme.hot.y, p.matrixTheme.hot.z)

        let depthRaw = p.needsDepth ? depthFrame?() : nil
        depthProgress = min(max(depthProgress + (depthRaw != nil ? dt : -dt) / 1.0, 0), 1)
        u.depthFade = Float(depthProgress * depthProgress * (3 - 2 * depthProgress))
        let maskRaw = p.needsMask ? maskFrame?() : nil
        u.maskOn = maskRaw != nil ? 1 : 0

        // the black hole: where it is, how big
        let hole = holeCenter(p, t: t, dt: dt, mirror: mirror, camScale: SIMD2(Double(u.camScaleX), Double(u.camScaleY)))
        holePosition = hole
        u.bhOn = p.holeActive ? 1 : 0
        u.bhX = Float(hole.x)
        u.bhY = Float(hole.y)
        u.bhDist = Float(25 / max(p.holeSize, 0.3))

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
        cp.holeOn = u.bhOn
        (cp.holeX, cp.holeY) = (u.bhX, u.bhY)
        cp.holeBend = Float(p.holeBend)
        cp.holePull = Float(p.holePull)
        cp.holeLight = Float(p.holeLight)
        cp.glow = Float(p.glow) * bloomStrength(p)
        cp.fade = Float(fade)
        cp.vignette = p.background == .sameAsYou ? (p.subject == .matrix ? 0.5 : 0.28) : 0.18
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

        // 4. your room with you removed, blurred (blurred / tidy backgrounds)
        if p.background == .blurred || p.background == .tidy {
            pass(cmd, roomA, roomDownPSO) { e in
                e.setFragmentTexture(cam, index: 0)
                e.setFragmentTexture(maskTex, index: 1)
                e.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                e.setFragmentBytes(&cp, length: MemoryLayout<CamParams>.stride, index: 1)
            }
            for spread in (p.background == .blurred ? [1.5, 3.0, 5.0] : [1.5, 3.0]) as [Float] {
                blur(cmd, roomA, roomB, SIMD2(1, 0), spread)
                blur(cmd, roomB, roomA, SIMD2(0, 1), spread)
            }
        }

        // 5. background (ray-marched scenes at half size on very large screens)
        let bgTex: MTLTexture = (p.background.isRayMarched && height > 1100) ? bgHalf : bgFull
        if p.background != .sameAsYou {
            var ub = u
            ub.resX = Float(bgTex.width)
            ub.resY = Float(bgTex.height)
            ub.cellH = ub.resY / Float(p.glyphRows)
            pass(cmd, bgTex, backgroundPSO) { e in
                e.setFragmentTexture(cam, index: 0)
                e.setFragmentTexture(self.roomA, index: 1)
                e.setFragmentTexture(lum, index: 2)
                e.setFragmentTexture(self.atlas.texture, index: 3)
                e.setFragmentTexture(geometry, index: 4)
                e.setFragmentBytes(&ub, length: MemoryLayout<Uniforms>.stride, index: 0)
                e.setFragmentBytes(&cp, length: MemoryLayout<CamParams>.stride, index: 1)
            }
            // soft copy of the background, for light wrapping onto your edges
            var texel = SIMD2<Float>(1 / Float(bgTex.width), 1 / Float(bgTex.height))
            pass(cmd, bgSoftA, brightPSO) { e in
                e.setFragmentTexture(bgTex, index: 0)
                var threshold: Float = 0
                e.setFragmentBytes(&texel, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
                e.setFragmentBytes(&threshold, length: MemoryLayout<Float>.stride, index: 1)
            }
            blur(cmd, bgSoftA, bgSoftB, SIMD2(1, 0), 2)
            blur(cmd, bgSoftB, bgSoftA, SIMD2(0, 1), 2)
        }

        // 6. your silhouette (the whole picture when the room takes your look)
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

        // 7. ghost trails (only drawn for that effect; a full-size pass is not free on big screens)
        var trailNow = transparent
        if p.subject == .effect && p.effect == .ghost {
            if !trailsLive { clear(trail, 0); trailsLive = true }
            let now = trail[trailIndex], prev = trail[1 - trailIndex]
            trailIndex = 1 - trailIndex
            pass(cmd, now, trailPSO) { e in
                e.setFragmentTexture(prev, index: 0)
                e.setFragmentTexture(self.subjectTex, index: 1)
                e.setFragmentBytes(&cp, length: MemoryLayout<CamParams>.stride, index: 1)
            }
            trailNow = now
        } else {
            trailsLive = false
        }

        // 8. composite: background, trails, you, and wisps of you falling into the hole
        pass(cmd, compTex, compositePSO) { e in
            e.setFragmentTexture(bgTex, index: 0)
            e.setFragmentTexture(self.subjectTex, index: 1)
            e.setFragmentTexture(trailNow, index: 2)
            e.setFragmentTexture(self.bgSoftA, index: 3)
            e.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            e.setFragmentBytes(&cp, length: MemoryLayout<CamParams>.stride, index: 1)
        }

        // 9. glow from the bright parts
        if cp.glow > 0.001 {
            var texel = SIMD2<Float>(1 / Float(width), 1 / Float(height))
            // Matrix code glows all over (like the film); other looks only from their bright parts.
            var threshold: Float = p.subject == .matrix ? 0 : (p.subject == .material ? 0.62 : 0.55)
            pass(cmd, glowA, brightPSO) { e in
                e.setFragmentTexture(self.compTex, index: 0)
                e.setFragmentBytes(&texel, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
                e.setFragmentBytes(&threshold, length: MemoryLayout<Float>.stride, index: 1)
            }
            blur(cmd, glowA, glowB, SIMD2(1, 0), 1)
            blur(cmd, glowB, glowA, SIMD2(0, 1), 1)
            var texel2 = SIMD2<Float>(1 / Float(glowA.width), 1 / Float(glowA.height))
            var none: Float = 0
            pass(cmd, glowC, brightPSO) { e in
                e.setFragmentTexture(self.glowA, index: 0)
                e.setFragmentBytes(&texel2, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
                e.setFragmentBytes(&none, length: MemoryLayout<Float>.stride, index: 1)
            }
            blur(cmd, glowC, glowD, SIMD2(1, 0), 1.6)
            blur(cmd, glowD, glowC, SIMD2(0, 1), 1.6)
        }

        // 10. final picture: glow, wipe in/out, fade, vignette
        let out = outputs[outputIndex]
        outputIndex = (outputIndex + 1) % outputs.count
        pass(cmd, out, finalPSO) { e in
            e.setFragmentTexture(self.compTex, index: 0)
            e.setFragmentTexture(self.glowA, index: 1)
            e.setFragmentTexture(self.glowC, index: 2)
            e.setFragmentTexture(cam, index: 3)
            e.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            e.setFragmentBytes(&cp, length: MemoryLayout<CamParams>.stride, index: 1)
        }
        onFrame?(out, cmd)
        then?(out, cmd)
        cmd.addCompletedHandler { [weak self] _ in self?.publish(out) }
        cmd.commit()
        return cmd
    }

    /// How much the bright parts of this look glow (before the user's Glow setting).
    private func bloomStrength(_ p: Preset) -> Float {
        var k: Float
        switch p.subject {
        case .matrix: k = 1.5
        case .material: k = p.material.bloom
        case .effect: k = 0.6
        case .fill: k = 0.35
        case .real: k = 0.15
        }
        if p.background == .matrix { k = max(k, 0.8) }
        if p.holeActive { k = max(k, 0.45) }
        return k
    }

    /// The hole's screen position: where you put it, or circling your head.
    private func holeCenter(_ p: Preset, t: Double, dt: Double, mirror: Bool, camScale: SIMD2<Double>) -> SIMD2<Double> {
        var target = SIMD2(p.holeX, p.holeY)
        // Matrix Eyes Cam: the position is set as seen in the (mirrored) preview; the call sees it flipped.
        if !mirrorsPicture && p.mirror { target.x = 1 - target.x }
        if p.holeMotion == .orbit, let face = faceRect?() {
            var c = SIMD2((Double(face.midX) - 0.5) / camScale.x + 0.5, (Double(face.midY) - 0.5) / camScale.y + 0.5)
            if mirror { c.x = 1 - c.x }
            let head = smoothedHead.map { $0 + (c - $0) * min(dt * 4, 1) } ?? c
            smoothedHead = head
            let aspect = Double(width) / Double(height)
            let r = 0.32 * (0.6 + 0.4 * p.holeSize)
            let a = t * 0.35
            target = head + SIMD2(cos(a) * r / aspect, sin(a) * r * 0.45 - 0.05)
        } else {
            // a gentle drift so it never looks pasted on
            target += SIMD2(0.008 * sin(t * 0.07), 0.006 * sin(t * 0.05 + 1))
        }
        return target
    }

    private func publish(_ tex: MTLTexture) {
        lock.lock()
        latestOutput = tex
        lock.unlock()
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

    private func buildSizedResources() {
        let w = width, h = height
        func tex(_ w: Int, _ h: Int, _ f: MTLPixelFormat, mip: Bool = false, storage: MTLStorageMode = .private) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: max(w, 1), height: max(h, 1), mipmapped: mip)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = storage
            return device.makeTexture(descriptor: d)!
        }
        lumTex = (0..<2).map { _ in tex(w / 4, h / 4, .r16Float, mip: true) }
        roomA = tex(w / 4, h / 4, .rgba16Float)
        roomB = tex(w / 4, h / 4, .rgba16Float)
        bgFull = tex(w, h, .rgba16Float)
        bgHalf = tex(w / 2, h / 2, .rgba16Float)
        bgSoftA = tex(w / 4, h / 4, .rgba16Float)
        bgSoftB = tex(w / 4, h / 4, .rgba16Float)
        subjectTex = tex(w, h, .rgba16Float)
        compTex = tex(w, h, .rgba16Float)
        glowA = tex(w / 4, h / 4, .rgba16Float)
        glowB = tex(w / 4, h / 4, .rgba16Float)
        glowC = tex(w / 8, h / 8, .rgba16Float)
        glowD = tex(w / 8, h / 8, .rgba16Float)
        trail = (0..<2).map { _ in tex(w, h, .rgba16Float) }
        outputs = (0..<3).map { _ in tex(w, h, .bgra8Unorm, storage: .shared) }
        lock.lock()
        latestOutput = nil
        lock.unlock()
        clear(lumTex, 0.3)
        clear(trail, 0)
        clear([bgSoftA, glowA, glowC, bgFull], 0)
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

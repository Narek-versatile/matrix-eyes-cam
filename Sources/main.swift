import AppKit
import ImageIO
import MetalKit
import UniformTypeIdentifiers

/// Offline check: run a look on a still photo instead of the camera and write a PNG.
///   MatrixEyesCam --render-test <input> <output.png> [bg=space subject=material material=chrome ...]
func runRenderTest(_ args: [String]) -> Int32 {
    guard args.count >= 2 else {
        print("usage: --render-test <input> <output.png> [key=value ...]")
        return 2
    }
    var preset = Preset(name: "test")
    var seconds = 6.0
    var size = (1280, 720)
    var mirrored = false
    for kv in args.dropFirst(2) {
        let parts = kv.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        let (k, v) = (parts[0], parts[1])
        func pick<E: CaseIterable>(_ type: E.Type) -> E? { E.allCases.first { "\($0)" == v } }
        let d = Double(v) ?? 0
        switch k {
        case "preset": if let b = Preset.builtIns.first(where: { $0.name == v }) { preset = b }
        case "look": if let i = Int(v), i >= 1, i <= Preset.builtIns.count { preset = Preset.builtIns[i - 1] }
        case "bg": preset.background = pick(BackgroundKind.self) ?? preset.background
        case "subject": preset.subject = pick(SubjectMode.self) ?? preset.subject
        case "effect": preset.effect = pick(SubjectEffect.self) ?? preset.effect
        case "material": preset.material = pick(MaterialLook.self) ?? preset.material
        case "fill": preset.fill = pick(FillKind.self) ?? preset.fill
        case "grade": preset.grade = pick(Grade.self) ?? preset.grade
        case "theme": preset.matrixTheme = pick(MatrixTheme.self) ?? preset.matrixTheme
        case "bh": preset.blackHole = v == "1"
        case "hx": preset.holeX = d
        case "hy": preset.holeY = d
        case "hsize": preset.holeSize = d
        case "bend": preset.holeBend = d
        case "pull": preset.holePull = d
        case "light": preset.holeLight = d
        case "glow": preset.glow = d
        case "rows": preset.glyphRows = d
        case "t": seconds = d
        case "size": let wh = v.split(separator: "x").compactMap { Int($0) }; if wh.count == 2 { size = (wh[0], wh[1]) }
        case "mirror": mirrored = v == "1"
        case "media": preset.mediaPath = v
        case "accent": preset.accent = v.split(separator: ",").compactMap { Double($0) }
        default: break
        }
    }
    preset.mirror = mirrored
    do {
        let device = MTLCreateSystemDefaultDevice()!
        let engine = try Engine(device: device, width: size.0, height: size.1, preset: preset)
        engine.mirrorsPicture = mirrored
        let url = URL(fileURLWithPath: args[0])
        let image = try MTKTextureLoader(device: device).newTexture(URL: url, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft])
        engine.cameraFrame = { (image, nil) }
        if let path = preset.mediaPath { engine.media = MediaSource(url: URL(fileURLWithPath: path), device: device) }
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            let masker = PersonMasker(device: device)
            if let mask = masker.estimate(cg) { engine.maskFrame = { mask } }
            engine.faceRect = { masker.latestFace() }
            if preset.needsDepth, let depth = try DepthEstimator(device: device).estimate(cg) { engine.depthFrame = { depth } }
        }
        var gpu: [Double] = []
        var last: MTLCommandBuffer?
        for i in 0..<45 {
            let cmd = engine.renderFrame(time: seconds - Double(44 - i) / 30)
            cmd?.waitUntilCompleted()
            if let cmd, i > 5 { gpu.append(cmd.gpuEndTime - cmd.gpuStartTime) }
            last = cmd
        }
        _ = last
        gpu.sort()
        print(String(format: "GPU per frame at %dx%d: median %.2f ms", engine.width, engine.height, gpu[gpu.count / 2] * 1000))
        guard let out = engine.latest(), let cg = Engine.image(from: out),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return 1 }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest) ? 0 : 1
    } catch {
        print("render test failed: \(error)")
        return 1
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--render-test") {
    exit(runRenderTest(Array(CommandLine.arguments[(i + 1)...])))
}

#if STUDIO
StudioApp.main()
#else
print("Engine-only build: use --render-test")
#endif

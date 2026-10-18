import AppKit
import Combine
import ImageIO
import Metal
import MetalKit
import SwiftUI

/// Owns the camera, the analysis (cut-out, depth), the engine and the active look.
@MainActor
final class StudioModel: ObservableObject {
    let store = PresetStore()
    @Published private(set) var preset: Preset
    @Published var cameraProblem: String?
    @Published var mirrorPreview = true
    @Published private(set) var framesPerSecond: Double = 0
    @Published var virtualCamera = VirtualCameraStatus.notInstalled
    @Published var installMessage: String?
    private let installer = ExtensionInstaller()

    let device: MTLDevice?
    let engine: Engine?
    let startupError: String?

    private let camera = Camera()
    private var depth: DepthEstimator?
    private var masker: PersonMasker?
    private let renderQueue = DispatchQueue(label: "matrix-eyes-cam.render", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var frameTimes: [Double] = []
    var output: VirtualCameraOutput?

    init() {
        preset = store.active
        device = MTLCreateSystemDefaultDevice()
        guard let device else {
            engine = nil
            startupError = "This Mac has no Metal GPU."
            return
        }
        do {
            engine = try Engine(device: device, preset: store.active)
            startupError = nil
        } catch {
            engine = nil
            startupError = "Couldn't start the renderer: \(error)"
            return
        }
        depth = try? DepthEstimator(device: device)
        masker = PersonMasker(device: device)
        loadMedia()
    }

    // MARK: - Running

    func start() {
        guard let engine, let device, timer == nil else { return }
        let depth = self.depth, masker = self.masker
        let env = ProcessInfo.processInfo.environment
        if let path = env["MATRIX_CAM_TEST_IMAGE"] {
            // Developer check: a still photo stands in for the camera (no camera is opened).
            useTestImage(path, device: device, engine: engine)
        } else {
            engine.cameraFrame = { [camera] in camera.latest() }
            engine.depthFrame = { depth?.latestTexture() }
            engine.maskFrame = { masker?.latestTexture() }
            camera.onPixelBuffer = { [weak engine] buffer in
                guard let engine else { return }
                let p = engine.preset
                masker?.submit(buffer)
                if p.needsDepth { depth?.submit(buffer) }
            }
            camera.onProblem = { [weak self] message in self?.cameraProblem = message }
            camera.start(device: device)
        }
        if let dir = env["MATRIX_CAM_SNAPSHOTS"] { runSnapshots(into: dir) }

        output = VirtualCameraOutput(device: device)
        output?.onStatus = { [weak self] status in Task { @MainActor in self?.virtualCamera = status } }
        if let output { engine.onFrame = { tex, cmd in output.send(tex, in: cmd) } }

        let t = DispatchSource.makeTimerSource(queue: renderQueue)
        t.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(2))
        t.setEventHandler { [weak self, weak engine] in
            engine?.renderFrame()
            let now = CACurrentMediaTime()
            Task { @MainActor in self?.tick(now) }
        }
        t.resume()
        timer = t
    }

    private func useTestImage(_ path: String, device: MTLDevice, engine: Engine) {
        let url = URL(fileURLWithPath: path)
        guard let tex = try? MTKTextureLoader(device: device).newTexture(URL: url, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft]),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        engine.cameraFrame = { (tex, nil) }
        let mask = masker?.estimate(cg)
        let depthTex = depth?.estimate(cg)
        engine.maskFrame = { mask }
        engine.depthFrame = { depthTex }
    }

    /// Developer check (MATRIX_CAM_SNAPSHOTS=dir): switches through a few looks in the running app,
    /// saving each call frame and the controls panel as PNGs, then quits. Saved looks are untouched.
    private func runSnapshots(into dir: String) {
        let looks = Array(store.presets.prefix(5))
        let original = store.activeID
        for (i, look) in looks.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5 + Double(i) * 1.6) { [weak self] in
                guard let self else { return }
                self.preset = look
                self.engine?.preset = look
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.6 + Double(i) * 1.6) { [weak self] in
                guard let self, let frame = self.engine?.latest(), let image = Engine.image(from: frame) else { return }
                Self.writePNG(image, to: "\(dir)/frame-\(i).png")
                if let panel = self.renderControls() { Self.writePNG(panel, to: "\(dir)/controls-\(i).png") }
                FileHandle.standardError.write(Data("snapshot \(i): \(look.name), fps \(Int(self.framesPerSecond)), camera: \(self.virtualCamera.text)\n".utf8))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5 + Double(looks.count) * 1.6) { [weak self] in
            self?.store.select(original)
            NSApp.terminate(nil)
        }
    }

    private func renderControls() -> CGImage? {
        let host = NSHostingView(rootView: ControlsView().environmentObject(self).frame(width: 360, height: 900).preferredColorScheme(.dark))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 900)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.cgImage
    }

    private static func writePNG(_ image: CGImage, to path: String) {
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    private func tick(_ now: Double) {
        frameTimes.append(now)
        frameTimes.removeAll { now - $0 > 1 }
        if frameTimes.count % 15 == 0 { framesPerSecond = Double(frameTimes.count) }
    }

    func installCamera() {
        installer.onMessage = { [weak self] text in self?.installMessage = text }
        installer.install()
    }

    // MARK: - Looks

    func update(_ change: (inout Preset) -> Void) {
        var p = preset
        change(&p)
        let mediaChanged = p.mediaPath != preset.mediaPath
        preset = p
        engine?.preset = p
        store.active = p
        if mediaChanged { loadMedia() }
    }

    func select(_ id: UUID) {
        store.select(id)
        preset = store.active
        engine?.preset = preset
        loadMedia()
    }

    func saveAsNew(named name: String) {
        store.saveCopy(named: name)
        preset = store.active
    }

    func deleteActive() {
        store.delete(preset.id)
        select(store.activeID)
    }

    private func loadMedia() {
        guard let device, let path = preset.mediaPath else { engine?.media = nil; return }
        engine?.media = MediaSource(url: URL(fileURLWithPath: path), device: device)
    }

    func chooseMedia() {
        let panel = NSOpenPanel()
        panel.title = "Fill your silhouette with…"
        panel.allowedContentTypes = [.image, .movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        update {
            $0.mediaPath = url.path
            $0.subject = .fill
            $0.fill = .media
        }
    }
}

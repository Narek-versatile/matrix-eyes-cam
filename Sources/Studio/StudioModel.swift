import AppKit
import Combine
import ImageIO
import Metal
import MetalKit
import SwiftUI

/// Owns the camera, the analysis (cut-out, depth), the engine, the look and the virtual camera.
@MainActor
final class StudioModel: ObservableObject {
    let look = LookModel(folder: "Matrix Eyes Cam", defaultLook: "Silver Surfer in space")
    @Published var cameraProblem: String?
    @Published private(set) var framesPerSecond: Double = 0
    @Published var virtualCamera = VirtualCameraStatus.notInstalled
    @Published var installMessage: String?
    @Published var countdown: Int?
    @Published var toast: String?

    let device: MTLDevice?
    let engine: Engine?
    let startupError: String?

    private let camera = Camera()
    private var depth: DepthEstimator?
    private var masker: PersonMasker?
    private let installer = ExtensionInstaller()
    private let renderQueue = DispatchQueue(label: "matrix-eyes-cam.render", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var frameTimes: [Double] = []
    private var countdownToken = 0
    private var cancellables: Set<AnyCancellable> = []
    var output: VirtualCameraOutput?

    var preset: Preset { look.preset }

    init() {
        device = MTLCreateSystemDefaultDevice()
        guard let device else {
            engine = nil
            startupError = "This Mac has no Metal GPU."
            return
        }
        do {
            engine = try Engine(device: device, preset: look.preset)
            startupError = nil
        } catch {
            engine = nil
            startupError = "Couldn't start the renderer: \(error)"
            return
        }
        engine?.mirrorsPicture = false          // calls always get the true picture
        depth = try? DepthEstimator(device: device)
        masker = PersonMasker(device: device)
        look.depthAvailable = depth != nil
        look.onChange = { [weak self] p, animated in
            guard let self else { return }
            let mediaChanged = p.mediaPath != self.engine?.preset.mediaPath
            self.engine?.setPreset(p, animated: animated)
            if mediaChanged { self.loadMedia() }
        }
        look.takePhoto = { [weak self] in self?.takePhoto() }
        look.askForPhotoFolder = { [weak self] done in self?.askForPhotoFolder(done) }
        // re-publish the look's changes so views observing the studio update too
        look.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
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
            engine.faceRect = { masker?.latestFace() }
            camera.onPixelBuffer = { [weak engine] buffer in
                guard let engine else { return }
                let p = engine.preset
                if p.needsMask || (p.holeActive && p.holeMotion == .orbit) { masker?.submit(buffer) }
                if p.needsDepth { depth?.submit(buffer) }
            }
            camera.onProblem = { [weak self] message in self?.cameraProblem = message }
            camera.start(device: device)
        }
        if let dir = env["MATRIX_CAM_SNAPSHOTS"] { runSnapshots(into: dir) }
        // `open -a "Matrix Eyes Cam" --args --install-camera` does what the Install button does.
        if CommandLine.arguments.contains("--install-camera") { installCamera() }

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

    private func tick(_ now: Double) {
        frameTimes.append(now)
        frameTimes.removeAll { now - $0 > 1 }
        if frameTimes.count % 15 == 0 { framesPerSecond = Double(frameTimes.count) }
    }

    func installCamera() {
        installer.onMessage = { [weak self] text in self?.installMessage = text }
        installer.install()
    }

    private func loadMedia() {
        guard let device, let path = look.preset.mediaPath else { engine?.media = nil; return }
        engine?.media = MediaSource(url: URL(fileURLWithPath: path), device: device)
    }

    // MARK: - Photos

    func takePhoto() {
        let seconds = look.photoTimer
        guard seconds > 0 else { shoot(); return }
        countdownToken += 1
        let token = countdownToken
        func tick(_ n: Int) {
            guard token == countdownToken else { return }
            if n == 0 {
                countdown = nil
                shoot()
                return
            }
            countdown = n
            NSSound(named: "Tink")?.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tick(n - 1) }
        }
        tick(seconds)
    }

    func cancelCountdown() {
        countdownToken += 1
        countdown = nil
    }

    private func shoot() {
        NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Shutter.aif",
                byReference: true)?.play()
        guard let frame = engine?.latest(), let image = Engine.image(from: frame) else { return }
        let lookName = look.preset.name
        if let folder = look.photos.folder {
            store(image, in: folder, look: lookName)
        } else {
            askForPhotoFolder { [weak self] folder in
                if let folder { self?.store(image, in: folder, look: lookName) } else { self?.showToast("Photo not saved") }
            }
        }
    }

    private func store(_ image: CGImage, in folder: URL, look name: String) {
        do {
            _ = try look.photos.write(image, in: folder, look: name)
            showToast("Photo saved to \(folder.lastPathComponent)")
        } catch {
            showToast("Couldn't save there; pick another folder")
            askForPhotoFolder { [weak self] new in
                if let new { self?.store(image, in: new, look: name) }
            }
        }
    }

    private func askForPhotoFolder(_ done: @escaping (URL?) -> Void) {
        look.photos.chooseFolder(over: NSApp.keyWindow) { [weak self] url in
            self?.look.refreshPhotoFolder()
            done(url)
        }
    }

    private func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.toast == text { self?.toast = nil }
        }
    }

    // MARK: - Developer checks

    private func useTestImage(_ path: String, device: MTLDevice, engine: Engine) {
        let url = URL(fileURLWithPath: path)
        guard let tex = try? MTKTextureLoader(device: device).newTexture(URL: url, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft]),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        engine.cameraFrame = { (tex, nil) }
        let mask = masker?.estimate(cg)
        let depthTex = depth?.estimate(cg)
        let masker = self.masker
        engine.maskFrame = { mask }
        engine.depthFrame = { depthTex }
        engine.faceRect = { masker?.latestFace() }
    }

    /// MATRIX_CAM_SNAPSHOTS=dir: switches through a few looks in the running app, saving each
    /// frame and the controls panel as PNGs, then quits. Saved looks are untouched.
    private func runSnapshots(into dir: String) {
        let looks = [2, 16, 0, 11, 13].compactMap { $0 < look.store.presets.count ? look.store.presets[$0] : nil }
        for (i, item) in looks.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5 + Double(i) * 1.8) { [weak self] in
                self?.look.select(item.id)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.9 + Double(i) * 1.8) { [weak self] in
                guard let self, let frame = self.engine?.latest(), let image = Engine.image(from: frame) else { return }
                Self.writePNG(image, to: "\(dir)/frame-\(i).png")
                if let panel = self.renderControls() { Self.writePNG(panel, to: "\(dir)/controls-\(i).png") }
                FileHandle.standardError.write(Data("snapshot \(i): \(item.name), fps \(Int(self.framesPerSecond)), camera: \(self.virtualCamera.text)\n".utf8))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.8 + Double(looks.count) * 1.8) { NSApp.terminate(nil) }
    }

    private func renderControls() -> CGImage? {
        let host = NSHostingView(rootView: ControlsView().environmentObject(self).frame(width: 360, height: 1400).preferredColorScheme(.dark))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 1400)
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
}

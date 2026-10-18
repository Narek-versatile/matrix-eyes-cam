import AppKit
import MetalKit
import SwiftUI

struct StudioApp: App {
    @StateObject private var model = StudioModel()

    var body: some Scene {
        WindowGroup("Matrix Eyes Cam", id: "studio") {
            StudioView()
                .environmentObject(model)
                .frame(minWidth: 1040, minHeight: 620)
                .onAppear { model.start() }
        }
        .windowStyle(.hiddenTitleBar)

        // A borderless view of exactly what the call receives (for screen-capture tools like OBS).
        Window("Output", id: "output") {
            PreviewView(mirror: false)
                .environmentObject(model)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .background(Color.black)
        }
        .defaultSize(width: 960, height: 540)

        MenuBarExtra("Matrix Eyes Cam", systemImage: "camera.filters") {
            MenuBarContent().environmentObject(model)
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var model: StudioModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Virtual camera: \(model.virtualCamera.text)")
        Divider()
        ForEach(model.store.presets) { p in
            Button {
                model.select(p.id)
            } label: {
                if p.id == model.preset.id { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
            }
        }
        Divider()
        Button("Open Studio") {
            openWindow(id: "studio")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit Matrix Eyes Cam") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

/// The finished frame, drawn into the window (mirrored like a mirror, unless asked not to).
struct PreviewView: NSViewRepresentable {
    @EnvironmentObject var model: StudioModel
    var mirror: Bool? = nil

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: model.device)
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 30
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.mirror = mirror ?? model.mirrorPreview
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, MTKViewDelegate {
        let model: StudioModel
        var mirror = true
        private var pipeline: MTLRenderPipelineState?

        init(model: StudioModel) { self.model = model }

        func attach(to view: MTKView) {
            view.delegate = self
            pipeline = try? model.engine?.previewPipeline(view.colorPixelFormat)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let engine = model.engine, let pipeline, let frame = engine.latest(),
                  let drawable = view.currentDrawable, let rp = view.currentRenderPassDescriptor,
                  let cmd = engine.queue.makeCommandBuffer(),
                  let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
            let viewAspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
            let frameAspect = Float(frame.width) / Float(frame.height)
            var p = PreviewParams(mirror: mirror ? 1 : 0,
                                  scaleX: viewAspect > frameAspect ? frameAspect / viewAspect : 1,
                                  scaleY: viewAspect > frameAspect ? 1 : viewAspect / frameAspect)
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(frame, index: 0)
            enc.setFragmentBytes(&p, length: MemoryLayout<PreviewParams>.stride, index: 0)
            enc.setFragmentSamplerState(engine.sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
            cmd.present(drawable)
            cmd.commit()
        }
    }
}

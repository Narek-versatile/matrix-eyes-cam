import AppKit
import SwiftUI

struct StudioView: View {
    @EnvironmentObject var model: StudioModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 10) {
                ZStack(alignment: .topLeading) {
                    PreviewView()
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .overlay { holeDragArea }
                        .overlay { countdownAndToast }
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Text("PREVIEW · \(Int(model.framesPerSecond)) FPS")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(12)
                        .allowsHitTesting(false)
                }
                if let problem = model.cameraProblem ?? model.startupError {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Text(model.preset.holeActive
                     ? "Drag on the picture to move the black hole. Others see you un-mirrored (text reads correctly for them)."
                     : "Others see you un-mirrored (text reads correctly for them). The preview can be mirrored, like a mirror.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.06))

            Divider()

            ControlsView()
                .frame(width: 360)
        }
        .preferredColorScheme(.dark)
    }

    /// Dragging on the preview moves the black hole (stored as seen in the preview).
    @ViewBuilder private var holeDragArea: some View {
        if model.preset.holeActive {
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        model.look.placeHole(at: CGPoint(x: v.location.x / max(geo.size.width, 1),
                                                         y: v.location.y / max(geo.size.height, 1)))
                    })
                    .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
            }
        }
    }

    private var countdownAndToast: some View {
        ZStack {
            if let n = model.countdown {
                Text("\(n)")
                    .font(.system(size: 120, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 12)
                    .onTapGesture { model.cancelCountdown() }
            }
            if let toast = model.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(.black.opacity(0.65), in: Capsule())
                        .padding(.bottom, 16)
                }
                .allowsHitTesting(false)
            }
        }
    }
}

/// The shared look panel plus the Cam's own section (the virtual camera).
struct ControlsView: View {
    @EnvironmentObject var model: StudioModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        LookPanel(model: model.look, mirrorLabel: "Mirror the preview") {
            Section("Virtual camera") {
                LabeledContent("Status", value: model.virtualCamera.text)
                if model.virtualCamera == .notInstalled {
                    Button("Install virtual camera") { model.installCamera() }
                    Text(model.installMessage ?? "Then choose “Matrix Eyes Cam” as your camera in Meet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Open clean output window") { openWindow(id: "output") }
            }
        }
    }
}

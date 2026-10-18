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
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Text("PREVIEW · \(Int(model.framesPerSecond)) FPS")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(12)
                }
                if let problem = model.cameraProblem ?? model.startupError {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Text("Others see you un-mirrored (text reads correctly for them). The preview is mirrored, like a mirror.")
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
}

struct ControlsView: View {
    @EnvironmentObject var model: StudioModel
    @Environment(\.openWindow) private var openWindow
    @State private var newName = ""
    @State private var naming = false

    private var p: Preset { model.preset }

    var body: some View {
        Form {
            Section("Look") {
                Picker("Preset", selection: Binding(get: { model.preset.id }, set: { model.select($0) })) {
                    ForEach(model.store.presets) { Text($0.name).tag($0.id) }
                }
                HStack {
                    Button("Save as new look…") { newName = p.name + " copy"; naming = true }
                    Spacer()
                    if !p.builtIn { Button("Delete", role: .destructive) { model.deleteActive() } }
                }
            }

            Section("Background") {
                backgroundGrid
                if p.background.isGenerated {
                    slider("Speed", value: \.backgroundSpeed, range: 0...2.5)
                }
                if p.background == .space {
                    Toggle("Black hole", isOn: bind(\.blackHole))
                }
                if p.background == .tidy {
                    slider("Calm the room", value: \.tidyAmount, range: 0...1)
                }
            }

            Section("You") {
                Picker("Become", selection: bind(\.subject)) {
                    ForEach(SubjectMode.allCases) { Text($0.title).tag($0) }
                }
                switch p.subject {
                case .real:
                    gradePicker
                case .effect:
                    Picker("Effect", selection: bind(\.effect)) {
                        ForEach(SubjectEffect.allCases) { Text($0.title).tag($0) }
                    }
                    slider("Strength", value: \.strength, range: 0...1)
                    ColorPicker("Color", selection: accentBinding, supportsOpacity: false)
                    gradePicker
                case .material:
                    Picker("Material", selection: bind(\.material)) {
                        ForEach(MaterialLook.allCases) { Text($0.title).tag($0) }
                    }
                case .fill:
                    Picker("Fill with", selection: bind(\.fill)) {
                        ForEach(FillKind.allCases) { Text($0.title).tag($0) }
                    }
                    if p.fill == .media {
                        HStack {
                            Text(p.mediaPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Nothing chosen")
                                .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Spacer()
                            Button("Choose…") { model.chooseMedia() }
                        }
                    }
                    slider("Keep your features", value: \.keepFeatures, range: 0...1)
                case .matrix:
                    Text("You, made of digital rain, shaped in 3D.").foregroundStyle(.secondary)
                }
                slider("Blend edges with background", value: \.lightWrap, range: 0...1)
            }

            Section("Virtual camera") {
                LabeledContent("Status", value: model.virtualCamera.text)
                if model.virtualCamera == .notInstalled {
                    Button("Install virtual camera") { model.installCamera() }
                    Text(model.installMessage ?? "Then choose “Matrix Eyes Cam” as your camera in Meet. Installing needs a build signed by an Apple developer team (see PLAN.md); until then the Output window can be captured by tools like OBS.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Mirror the preview", isOn: $model.mirrorPreview)
                Button("Open clean output window") { openWindow(id: "output") }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $naming) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Save look").font(.headline)
                TextField("Name", text: $newName).frame(width: 280)
                HStack {
                    Spacer()
                    Button("Cancel") { naming = false }
                    Button("Save") { model.saveAsNew(named: newName); naming = false }
                        .keyboardShortcut(.defaultAction)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
        }
    }

    // MARK: - Pieces

    private var backgroundGrid: some View {
        let groups = ["Your room", "Animated scenes", "Impossible spaces"]
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(groups, id: \.self) { group in
                Text(group.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                    ForEach(BackgroundKind.allCases.filter { $0.group == group }) { kind in
                        Button { model.update { $0.background = kind } } label: {
                            VStack(spacing: 5) {
                                Image(systemName: kind.symbol).font(.system(size: 17))
                                Text(kind.title).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(p.background == kind ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(p.background == kind ? Color.accentColor : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var gradePicker: some View {
        Picker("Colour grade", selection: bind(\.grade)) {
            ForEach(Grade.allCases) { Text($0.title).tag($0) }
        }
    }

    private func slider(_ title: String, value: WritableKeyPath<Preset, Double>, range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            Slider(value: bind(value), in: range).frame(width: 170)
        }
    }

    private func bind<T>(_ key: WritableKeyPath<Preset, T>) -> Binding<T> {
        Binding(get: { model.preset[keyPath: key] }, set: { v in model.update { $0[keyPath: key] = v } })
    }

    private var accentBinding: Binding<Color> {
        Binding(get: {
            let a = model.preset.accent + [1, 1, 1]
            return Color(red: a[0], green: a[1], blue: a[2])
        }, set: { color in
            let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
            model.update { $0.accent = [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)] }
        })
    }
}

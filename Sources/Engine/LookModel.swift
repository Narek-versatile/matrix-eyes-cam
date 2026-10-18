import AppKit
import Combine
import SwiftUI

// Shared by Matrix Eyes and Matrix Eyes Cam (synced by scripts/sync-to-matrix-eyes.sh).

/// The current look and everything you can do to it, for the shared control panel. Each app owns
/// one (each keeps its own saved looks) and applies changes to its engine through `onChange`.
@MainActor
final class LookModel: ObservableObject {
    let store: PresetStore
    @Published private(set) var preset: Preset
    @Published var photoTimer: Int {
        didSet { if !PresetStore.isDeveloperCheck { UserDefaults.standard.set(photoTimer, forKey: "photoTimer") } }
    }
    @Published private(set) var photoFolderText: String
    @Published var depthAvailable = true

    let photos = PhotoSaver()
    /// Called with every change; `animated` is true when switching to another look.
    var onChange: ((Preset, _ animated: Bool) -> Void)?
    /// The app takes the photo (it knows what's on screen).
    var takePhoto: (() -> Void)?
    var askForPhotoFolder: ((@escaping (URL?) -> Void) -> Void)?

    static let timerChoices = [0, 3, 5, 10]

    init(folder: String, defaultLook: String) {
        store = PresetStore(folder: folder, defaultLook: defaultLook)
        preset = store.active
        let saved = UserDefaults.standard.integer(forKey: "photoTimer")
        photoTimer = LookModel.timerChoices.contains(saved) ? saved : 0
        photoFolderText = photos.displayPath
    }

    // MARK: - Changing the look

    func update(_ change: (inout Preset) -> Void) {
        var p = preset
        change(&p)
        guard p != preset else { return }
        let animated = p.background != preset.background || p.subject != preset.subject
        let mirrorChanged = p.mirror != preset.mirror
        preset = p
        store.active = p
        if mirrorChanged { store.setMirror(p.mirror) }
        onChange?(p, animated)
    }

    func select(_ id: UUID) {
        guard id != preset.id else { return }
        store.select(id)
        preset = store.active
        onChange?(preset, true)
    }

    func selectIndex(_ i: Int) {
        guard i >= 0, i < store.presets.count else { return }
        select(store.presets[i].id)
    }

    func next(_ step: Int = 1) {
        let all = store.presets
        guard let i = all.firstIndex(where: { $0.id == preset.id }) else { return }
        select(all[(i + step + all.count) % all.count].id)
    }

    func saveAsNew(named name: String) {
        store.saveCopy(named: name)
        preset = store.active
    }

    func deleteActive() {
        store.delete(preset.id)
        preset = store.active
        onChange?(preset, true)
    }

    func resetActive() {
        store.reset(preset.id)
        preset = store.active
        onChange?(preset, true)
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

    /// Moves the black hole to a point on the picture (0...1 as you see it) and parks it there.
    func placeHole(at point: CGPoint) {
        update {
            $0.holeX = min(max(Double(point.x), 0), 1)
            $0.holeY = min(max(Double(point.y), 0), 1)
            $0.holeMotion = .stay
        }
    }

    // MARK: - Photos

    func changePhotoFolder() {
        askForPhotoFolder? { [weak self] _ in self?.refreshPhotoFolder() }
    }

    func refreshPhotoFolder() { photoFolderText = photos.displayPath }

    /// An accent colour for the panel that suits the look.
    var accent: Color {
        let p = preset
        switch p.subject {
        case .matrix: return p.matrixTheme == .green ? Color(red: 0.55, green: 1, blue: 0.6) : Color(red: 1, green: 0.74, blue: 0.3)
        case .material:
            switch p.material {
            case .chrome: return Color(red: 0.72, green: 0.86, blue: 1)
            case .quartz: return Color(red: 0.97, green: 0.82, blue: 0.9)
            case .copper: return Color(red: 0.45, green: 0.86, blue: 0.72)
            case .bronze: return Color(red: 0.9, green: 0.64, blue: 0.32)
            case .doodle: return Color(red: 0.62, green: 0.72, blue: 1)
            case .print: return Color(red: 1, green: 0.42, blue: 0.38)
            }
        case .effect:
            let a = p.accent + [1, 1, 1]
            return Color(red: a[0], green: a[1], blue: a[2])
        default:
            return p.background == .space ? Color(red: 1, green: 0.75, blue: 0.45) : Color(red: 0.55, green: 0.8, blue: 1)
        }
    }

    var accentNSColor: NSColor { NSColor(accent) }
}

/// Every control, in one panel, used by both apps. Apps add their own sections through `extras`.
struct LookPanel<Extras: View>: View {
    @ObservedObject var model: LookModel
    var mirrorLabel: String
    var showPhotos = true
    @ViewBuilder var extras: () -> Extras

    @State private var naming = false
    @State private var newName = ""

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
                    if p.builtIn {
                        Button("Reset") { model.resetActive() }
                    } else {
                        Button("Delete", role: .destructive) { model.deleteActive() }
                    }
                }
            }

            Section("Background") {
                backgroundGrid
                if p.background.isGenerated { slider("Speed", \.backgroundSpeed, 0...2.5) }
                if p.background == .tidy { slider("Calm the room", \.tidyAmount, 0...1) }
            }

            if p.background == .space {
                Section("Black hole") {
                    Toggle("Show the black hole", isOn: bind(\.blackHole))
                    if p.blackHole {
                        slider("Size", \.holeSize, 0.5...2)
                        Picker("Position", selection: bind(\.holeMotion)) {
                            ForEach(HoleMotion.allCases) { Text($0.title).tag($0) }
                        }
                        if p.holeMotion == .stay {
                            Text("Drag on the picture to move it.").font(.caption).foregroundStyle(.secondary)
                        }
                        slider("Gravity bends you", \.holeBend, 0...1)
                        slider("Pulls you in", \.holePull, 0...1)
                        slider("Disk lights you", \.holeLight, 0...1)
                    }
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
                    slider("Strength", \.strength, 0...1)
                    ColorPicker("Colour", selection: accentBinding, supportsOpacity: false)
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
                    slider("Keep your features", \.keepFeatures, 0...1)
                case .matrix:
                    Text("You, made of digital rain, shaped in 3D.").foregroundStyle(.secondary)
                }
                if p.background != .sameAsYou { slider("Blend edges", \.lightWrap, 0...1) }
            }

            if p.usesMatrix {
                Section("Matrix code") {
                    Picker("Colour", selection: bind(\.matrixTheme)) {
                        ForEach(MatrixTheme.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Glyph size") {
                        Slider(value: Binding(get: { Preset.glyphRowsRange.upperBound + Preset.glyphRowsRange.lowerBound - model.preset.glyphRows },
                                              set: { v in model.update { $0.glyphRows = Preset.glyphRowsRange.upperBound + Preset.glyphRowsRange.lowerBound - v } }),
                               in: Preset.glyphRowsRange).frame(width: 170)
                    }
                    slider("Rain speed", \.rainSpeed, Preset.rainSpeedRange)
                }
            }

            Section("Picture") {
                slider("Brightness", \.brightness, Preset.brightnessRange)
                slider("Glow", \.glow, Preset.glowRange)
                Toggle("3D depth", isOn: bind(\.depth3D)).disabled(!model.depthAvailable)
                Toggle(mirrorLabel, isOn: bind(\.mirror))
            }

            if showPhotos {
                Section("Photos") {
                    HStack {
                        Text(model.photoFolderText).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Spacer()
                        Button("Change…") { model.changePhotoFolder() }
                    }
                    Picker("Timer", selection: $model.photoTimer) {
                        ForEach(LookModel.timerChoices, id: \.self) { Text($0 == 0 ? "Off" : "\($0) s").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if let take = model.takePhoto { Button("Take photo") { take() } }
                }
            }

            extras()
        }
        .formStyle(.grouped)
        .tint(model.accent)
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
        VStack(alignment: .leading, spacing: 10) {
            ForEach(BackgroundKind.groups, id: \.self) { group in
                Text(group.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                    ForEach(BackgroundKind.allCases.filter { $0.group == group }) { kind in
                        Button { model.update { $0.background = kind } } label: {
                            VStack(spacing: 5) {
                                Image(systemName: kind.symbol).font(.system(size: 17))
                                Text(kind.title).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.75)
                            }
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(p.background == kind ? model.accent.opacity(0.3) : Color.white.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(p.background == kind ? model.accent : .clear, lineWidth: 1.5))
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

    private func slider(_ title: String, _ key: WritableKeyPath<Preset, Double>, _ range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            Slider(value: bind(key), in: range).frame(width: 170)
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

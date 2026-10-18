import Foundation

// Shared by Matrix Eyes and Matrix Eyes Cam (synced by scripts/sync-to-matrix-eyes.sh).

enum BackgroundKind: Int, Codable, CaseIterable, Identifiable {
    case room = 0, blurred, tidy, space, matrix, aurora, synthwave, corridor, stairs, cathedral, sameAsYou
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .room: return "Room"
        case .blurred: return "Blurred room"
        case .tidy: return "Tidy room"
        case .space: return "Space"
        case .matrix: return "Matrix rain"
        case .aurora: return "Aurora"
        case .synthwave: return "Synthwave"
        case .corridor: return "Infinite corridor"
        case .stairs: return "Escher stairs"
        case .cathedral: return "Fractal cathedral"
        case .sameAsYou: return "Room in your look"
        }
    }

    var symbol: String {
        switch self {
        case .room: return "house"
        case .blurred: return "camera.aperture"
        case .tidy: return "sparkles"
        case .space: return "moon.stars"
        case .matrix: return "chevron.left.forwardslash.chevron.right"
        case .aurora: return "mountain.2"
        case .synthwave: return "sun.horizon"
        case .corridor: return "rectangle.portrait.on.rectangle.portrait"
        case .stairs: return "stairs"
        case .cathedral: return "square.grid.3x3.square"
        case .sameAsYou: return "cube.transparent"
        }
    }

    var group: String {
        switch self {
        case .sameAsYou, .room, .blurred, .tidy: return "Your room"
        case .space, .matrix, .aurora, .synthwave: return "Animated scenes"
        case .corridor, .stairs, .cathedral: return "Impossible spaces"
        }
    }

    static let groups = ["Your room", "Animated scenes", "Impossible spaces"]

    var isGenerated: Bool { [.space, .matrix, .aurora, .synthwave, .corridor, .stairs, .cathedral].contains(self) }
    /// Ray-marched scenes are smooth enough to render at a reduced size on very large screens.
    var isRayMarched: Bool { [.corridor, .stairs, .cathedral, .aurora].contains(self) }
}

enum SubjectMode: Int, Codable, CaseIterable, Identifiable {
    case real = 0, effect, material, fill, matrix
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .real: return "As you are"
        case .effect: return "Effect"
        case .material: return "Material"
        case .fill: return "Fill"
        case .matrix: return "Matrix code"
        }
    }
}

enum SubjectEffect: Int, Codable, CaseIterable, Identifiable {
    case edgeGlow = 1, hologram, neon, pixelate, ghost
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .edgeGlow: return "Edge glow"
        case .hologram: return "Hologram"
        case .neon: return "Neon outline"
        case .pixelate: return "Pixelate"
        case .ghost: return "Ghost trails"
        }
    }
}

enum Grade: Int, Codable, CaseIterable, Identifiable {
    case natural = 0, noir, warm, cyberpunk
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .natural: return "Natural"
        case .noir: return "Noir"
        case .warm: return "Warm film"
        case .cyberpunk: return "Cyberpunk"
        }
    }
}

enum MaterialLook: Int, Codable, CaseIterable, Identifiable {
    case chrome = 1, quartz, copper, bronze, doodle, print
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .chrome: return "Silver Surfer chrome"
        case .quartz: return "Quartz statue"
        case .copper: return "Verdigris copper"
        case .bronze: return "Bronze"
        case .doodle: return "Doodle"
        case .print: return "3D print"
        }
    }
    /// How strongly bright parts glow.
    var bloom: Float {
        switch self {
        case .chrome: return 0.45
        case .quartz: return 0.4
        case .copper: return 0.25
        case .bronze: return 0.3
        case .doodle: return 0
        case .print: return 0.2
        }
    }
}

enum FillKind: Int, Codable, CaseIterable, Identifiable {
    case media = 0, galaxy, fire, ocean, lava
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .media: return "Your image or video"
        case .galaxy: return "Galaxy"
        case .fire: return "Fire"
        case .ocean: return "Ocean"
        case .lava: return "Lava"
        }
    }
}

enum MatrixTheme: Int, Codable, CaseIterable, Identifiable {
    case green = 0, amber
    var id: Int { rawValue }
    var title: String { self == .green ? "Green" : "Amber" }
    /// Glyph colour (scaled by brightness, rolled off toward white by the tone curve) and stream heads.
    var base: SIMD3<Float> { self == .green ? SIMD3(0.40, 1.0, 0.46) : SIMD3(1.0, 0.58, 0.12) }
    var hot: SIMD3<Float> { self == .green ? SIMD3(0.92, 1.0, 0.94) : SIMD3(1.0, 0.93, 0.76) }
}

enum HoleMotion: Int, Codable, CaseIterable, Identifiable {
    case stay = 0, orbit
    var id: Int { rawValue }
    var title: String { self == .stay ? "Stays where you put it" : "Orbits your head" }
}

/// One complete look: background, what your silhouette becomes, the black hole and how it
/// treats you, Matrix settings and the picture. Both apps use this same model.
struct Preset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var builtIn = false

    // background
    var background: BackgroundKind = .space
    var backgroundSpeed: Double = 1
    var tidyAmount: Double = 0.7

    // black hole (in the Space background)
    var blackHole = true
    var holeSize: Double = 1            // 0.5 ... 2
    var holeMotion: HoleMotion = .stay
    var holeX: Double = 0.73            // screen position, 0...1 from the left (as you see the picture)
    var holeY: Double = 0.27            // 0...1 from the top
    var holeBend: Double = 0.5          // gravity bends your silhouette near it
    var holePull: Double = 0.5          // wisps of you spiral into it
    var holeLight: Double = 0.6         // the disk lights the side of you facing it

    // you
    var subject: SubjectMode = .real
    var effect: SubjectEffect = .edgeGlow
    var grade: Grade = .natural
    var material: MaterialLook = .chrome
    var fill: FillKind = .galaxy
    var mediaPath: String?
    var accent: [Double] = [0.35, 0.85, 1.0]
    var strength: Double = 0.7
    var keepFeatures: Double = 0.55
    var lightWrap: Double = 0.45

    // Matrix code (your silhouette, the whole room, or the rain background)
    var matrixTheme: MatrixTheme = .green
    var glyphRows: Double = 72          // rows of glyphs at arm's length; fewer = bigger glyphs
    var rainSpeed: Double = 1

    // picture
    var brightness: Double = 1
    var glow: Double = 1
    var depth3D = true
    var mirror = true                   // Matrix Eyes: mirror the picture. Cam: mirror only the preview.

    static let glyphRowsRange: ClosedRange<Double> = 30...160
    static let brightnessRange: ClosedRange<Double> = 0.25...3
    static let rainSpeedRange: ClosedRange<Double> = 0.2...4
    static let glowRange: ClosedRange<Double> = 0...2

    /// Whether this look needs the depth network (materials and Matrix code shade your 3D shape).
    var needsDepth: Bool { depth3D && (subject == .material || subject == .matrix) }
    /// Whether this look needs your cut-out at all.
    var needsMask: Bool { background != .sameAsYou && !(background == .room && subject == .real && grade == .natural) }
    var holeActive: Bool { background == .space && blackHole }
    var usesMatrix: Bool { subject == .matrix || background == .matrix }

    init(name: String) { self.name = name }

    enum CodingKeys: String, CodingKey {
        case id, name, builtIn, background, backgroundSpeed, tidyAmount
        case blackHole, holeSize, holeMotion, holeX, holeY, holeBend, holePull, holeLight
        case subject, effect, grade, material, fill, mediaPath, accent, strength, keepFeatures, lightWrap
        case matrixTheme, glyphRows, rainSpeed, brightness, glow, depth3D, mirror
    }

    /// Looks saved by older versions lack newer fields; those take their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var p = Preset(name: try c.decodeIfPresent(String.self, forKey: .name) ?? "Look")
        func v<T: Decodable>(_ key: CodingKeys, _ current: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil ?? current }
        p.id = v(.id, p.id)
        p.builtIn = v(.builtIn, p.builtIn)
        p.background = v(.background, p.background)
        p.backgroundSpeed = v(.backgroundSpeed, p.backgroundSpeed)
        p.tidyAmount = v(.tidyAmount, p.tidyAmount)
        p.blackHole = v(.blackHole, p.blackHole)
        p.holeSize = v(.holeSize, p.holeSize)
        p.holeMotion = v(.holeMotion, p.holeMotion)
        p.holeX = v(.holeX, p.holeX)
        p.holeY = v(.holeY, p.holeY)
        p.holeBend = v(.holeBend, p.holeBend)
        p.holePull = v(.holePull, p.holePull)
        p.holeLight = v(.holeLight, p.holeLight)
        p.subject = v(.subject, p.subject)
        p.effect = v(.effect, p.effect)
        p.grade = v(.grade, p.grade)
        p.material = v(.material, p.material)
        p.fill = v(.fill, p.fill)
        p.mediaPath = try? c.decodeIfPresent(String.self, forKey: .mediaPath)
        p.accent = v(.accent, p.accent)
        p.strength = v(.strength, p.strength)
        p.keepFeatures = v(.keepFeatures, p.keepFeatures)
        p.lightWrap = v(.lightWrap, p.lightWrap)
        p.matrixTheme = v(.matrixTheme, p.matrixTheme)
        p.glyphRows = v(.glyphRows, p.glyphRows)
        p.rainSpeed = v(.rainSpeed, p.rainSpeed)
        p.brightness = v(.brightness, p.brightness)
        p.glow = v(.glow, p.glow)
        p.depth3D = v(.depth3D, p.depth3D)
        p.mirror = v(.mirror, p.mirror)
        self = p
    }

    static func make(_ name: String, _ configure: (inout Preset) -> Void) -> Preset {
        var p = Preset(name: name)
        p.builtIn = true
        configure(&p)
        return p
    }

    /// The first eight are Matrix Eyes' keys 1–8.
    static let builtIns: [Preset] = [
        make("Matrix") { $0.background = .sameAsYou; $0.subject = .matrix },
        make("Matrix Amber") { $0.background = .sameAsYou; $0.subject = .matrix; $0.matrixTheme = .amber },
        make("Silver Surfer in space") { $0.background = .space; $0.subject = .material; $0.material = .chrome },
        make("Quartz statue") { $0.background = .sameAsYou; $0.subject = .material; $0.material = .quartz },
        make("Verdigris copper") { $0.background = .sameAsYou; $0.subject = .material; $0.material = .copper },
        make("Bronze") { $0.background = .sameAsYou; $0.subject = .material; $0.material = .bronze },
        make("Doodle") { $0.background = .sameAsYou; $0.subject = .material; $0.material = .doodle },
        make("3D print") { $0.background = .sameAsYou; $0.subject = .material; $0.material = .print },
        make("Tidy room") { $0.background = .tidy },
        make("Blurred room") { $0.background = .blurred },
        make("Neo in the rain") { $0.background = .matrix; $0.subject = .matrix },
        make("Hologram in the corridor") { $0.background = .corridor; $0.subject = .effect; $0.effect = .hologram },
        make("Statue on Escher's stairs") { $0.background = .stairs; $0.subject = .material; $0.material = .quartz },
        make("Bronze in the cathedral") { $0.background = .cathedral; $0.subject = .material; $0.material = .bronze },
        make("Neon synthwave") { $0.background = .synthwave; $0.subject = .effect; $0.effect = .neon; $0.accent = [1, 0.25, 0.85] },
        make("Made of galaxy") { $0.background = .space; $0.blackHole = false; $0.subject = .fill; $0.fill = .galaxy },
        make("Falling into the black hole") {
            $0.background = .space; $0.subject = .effect; $0.effect = .edgeGlow
            $0.holeX = 0.66; $0.holeY = 0.4; $0.holeSize = 1.3
            $0.holeBend = 0.9; $0.holePull = 0.9; $0.holeLight = 0.9
        },
        make("Aurora, noir") { $0.background = .aurora; $0.grade = .noir },
        make("Fire spirit") { $0.background = .cathedral; $0.subject = .fill; $0.fill = .fire },
        make("Ghost trails") { $0.background = .tidy; $0.subject = .effect; $0.effect = .ghost; $0.accent = [0.6, 0.4, 1.0] },
        make("As I am") { $0.background = .room },
    ]
}

/// Saved looks and which one is active, in Application Support/<folder>.
final class PresetStore: ObservableObject {
    @Published var presets: [Preset]
    @Published var activeID: UUID
    private let file: URL

    private struct Saved: Codable {
        var presets: [Preset]
        var activeID: UUID
    }

    init(folder: String, defaultLook: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("presets.json")
        let fallback = Preset.builtIns.first { $0.name == defaultLook } ?? Preset.builtIns[0]
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data),
           !saved.presets.isEmpty {
            // Built-ins come from the app (so new ones appear after updates), keeping any edits you saved.
            let builtIns = Preset.builtIns.map { b in saved.presets.first { $0.builtIn && $0.name == b.name } ?? b }
            let all = builtIns + saved.presets.filter { !$0.builtIn }
            presets = all
            activeID = all.contains { $0.id == saved.activeID } ? saved.activeID : fallback.id
            hadSavedFile = true
        } else {
            presets = Preset.builtIns
            activeID = fallback.id
            hadSavedFile = false
        }
    }

    /// False on the very first launch (nothing saved yet).
    let hadSavedFile: Bool

    var active: Preset {
        get { presets.first { $0.id == activeID } ?? presets[0] }
        set {
            if let i = presets.firstIndex(where: { $0.id == newValue.id }) { presets[i] = newValue }
            save()
        }
    }

    func select(_ id: UUID) {
        activeID = id
        save()
    }

    func saveCopy(named name: String) {
        var copy = active
        copy.id = UUID()
        copy.name = name
        copy.builtIn = false
        presets.append(copy)
        activeID = copy.id
        save()
    }

    func delete(_ id: UUID) {
        guard let p = presets.first(where: { $0.id == id }), !p.builtIn else { return }
        presets.removeAll { $0.id == id }
        if activeID == id { activeID = presets[0].id }
        save()
    }

    /// Restores a built-in look to how it ships.
    func reset(_ id: UUID) {
        guard let i = presets.firstIndex(where: { $0.id == id }), presets[i].builtIn,
              var original = Preset.builtIns.first(where: { $0.name == presets[i].name }) else { return }
        original.id = presets[i].id
        original.mirror = presets[i].mirror
        presets[i] = original
        save()
    }

    /// True while a developer check runs; nothing is saved then.
    static var isDeveloperCheck: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["MATRIX_SELFTEST"] != nil || env["MATRIX_KEYTEST"] != nil || env["MATRIX_CAM_SNAPSHOTS"] != nil
    }()

    /// Mirroring is a setting of the app, not of a look: it applies to all of them.
    func setMirror(_ on: Bool) {
        for i in presets.indices { presets[i].mirror = on }
        save()
    }

    func save() {
        // Developer checks never touch your saved looks.
        guard !PresetStore.isDeveloperCheck else { return }
        if let data = try? JSONEncoder().encode(Saved(presets: presets, activeID: activeID)) {
            try? data.write(to: file, options: .atomic)
        }
    }
}

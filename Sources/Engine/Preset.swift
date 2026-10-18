import Foundation

enum BackgroundKind: Int, Codable, CaseIterable, Identifiable {
    case room = 0, blurred, tidy, space, matrix, aurora, synthwave, corridor, stairs, cathedral
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
        }
    }

    var group: String {
        switch self {
        case .room, .blurred, .tidy: return "Your room"
        case .space, .matrix, .aurora, .synthwave: return "Animated scenes"
        case .corridor, .stairs, .cathedral: return "Impossible spaces"
        }
    }

    var isGenerated: Bool { rawValue >= BackgroundKind.space.rawValue }
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

/// One complete look: a background and what your silhouette becomes, with their settings.
struct Preset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var builtIn = false

    var background: BackgroundKind = .space
    var backgroundSpeed: Double = 1
    var blackHole = true
    var tidyAmount: Double = 0.7

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

    /// Whether this look needs the depth network (materials and Matrix code shade your 3D shape).
    var needsDepth: Bool { subject == .material || subject == .matrix }

    static let builtIns: [Preset] = [
        Preset(name: "Silver Surfer in space", builtIn: true, background: .space, blackHole: true,
               subject: .material, material: .chrome),
        Preset(name: "Tidy room", builtIn: true, background: .tidy, subject: .real),
        Preset(name: "Blurred room", builtIn: true, background: .blurred, subject: .real),
        Preset(name: "Neo", builtIn: true, background: .matrix, subject: .matrix),
        Preset(name: "Hologram in the corridor", builtIn: true, background: .corridor, subject: .effect,
               effect: .hologram, accent: [0.3, 0.85, 1.0]),
        Preset(name: "Statue on Escher's stairs", builtIn: true, background: .stairs, subject: .material,
               material: .quartz),
        Preset(name: "Bronze in the cathedral", builtIn: true, background: .cathedral, subject: .material,
               material: .bronze),
        Preset(name: "Neon synthwave", builtIn: true, background: .synthwave, subject: .effect, effect: .neon,
               accent: [1.0, 0.25, 0.85]),
        Preset(name: "Made of galaxy", builtIn: true, background: .space, blackHole: false, subject: .fill,
               fill: .galaxy),
        Preset(name: "Aurora, noir", builtIn: true, background: .aurora, subject: .real, grade: .noir),
        Preset(name: "Fire spirit", builtIn: true, background: .cathedral, subject: .fill, fill: .fire),
        Preset(name: "Ghost trails", builtIn: true, background: .tidy, subject: .effect, effect: .ghost,
               accent: [0.6, 0.4, 1.0]),
        Preset(name: "As I am", builtIn: true, background: .room, subject: .real),
    ]
}

/// Saved looks and which one is active, in Application Support.
final class PresetStore: ObservableObject {
    @Published var presets: [Preset]
    @Published var activeID: UUID

    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Matrix Eyes Cam", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("presets.json")
    }

    private struct Saved: Codable {
        var presets: [Preset]
        var activeID: UUID
    }

    init() {
        if let data = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode(Saved.self, from: data),
           !saved.presets.isEmpty {
            // Built-ins come from the app (so new ones appear after updates), keeping any edits you saved.
            let builtIns = Preset.builtIns.map { b in saved.presets.first { $0.builtIn && $0.name == b.name } ?? b }
            let all = builtIns + saved.presets.filter { !$0.builtIn }
            presets = all
            activeID = all.contains { $0.id == saved.activeID } ? saved.activeID : builtIns[0].id
        } else {
            presets = Preset.builtIns
            activeID = Preset.builtIns[0].id
        }
    }

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

    /// Saves the current settings as a new look.
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

    func save() {
        let saved = Saved(presets: presets, activeID: activeID)
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: Self.file, options: .atomic) }
    }
}

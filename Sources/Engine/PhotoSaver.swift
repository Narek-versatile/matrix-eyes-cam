import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Where photos go and how they're written. The folder is asked for the first time a photo is
/// taken, then remembered; it can be changed in the settings menu.
final class PhotoSaver {
    private static let key = "photoFolder"

    /// Used by the self-test so it never touches the saved setting.
    var overrideFolder: URL?

    /// The chosen folder, or nil if none was chosen yet (or it has since disappeared).
    var folder: URL? {
        get {
            if let overrideFolder { return overrideFolder }
            guard let path = UserDefaults.standard.string(forKey: Self.key) else { return nil }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set { UserDefaults.standard.set(newValue?.path, forKey: Self.key) }
    }

    /// Folder shown in the settings.
    var displayPath: String {
        folder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Asked on your first photo"
    }

    /// Asks where photos should be saved and remembers the answer. Calls back with nil if cancelled.
    func chooseFolder(over window: NSWindow?, completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Where should photos be saved?"
        panel.message = "Pick a folder for your Matrix Eyes photos. You can change it later in settings (Esc)."
        panel.prompt = "Save Photos Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first

        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { completion(nil); return }
            self?.folder = url
            completion(url)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(panel.runModal()) }
    }

    /// Writes a PNG into the chosen folder and returns its URL.
    func write(_ image: CGImage, in folder: URL, look: String) throws -> URL {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        var url = folder.appendingPathComponent("Matrix Eyes \(look) \(stamp.string(from: Date())).png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {   // two photos in the same second
            url = folder.appendingPathComponent("Matrix Eyes \(look) \(stamp.string(from: Date())) \(n).png")
            n += 1
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }
}

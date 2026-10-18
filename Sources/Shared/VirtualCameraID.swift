/// Identity shared by the studio app and the camera extension. Keep the two in step.
enum VirtualCameraID {
    static let deviceUID = "io.github.narek-versatile.matrix-eyes-cam.device"
    static let deviceUUID = "8D5B3A57-0F6E-4C1B-9E7A-3C2B1D0A9F41"     // stable across launches
    static let extensionBundleID = "io.github.narek-versatile.matrix-eyes-cam.extension"
    static let name = "Matrix Eyes Cam"
    static let width = 1280
    static let height = 720
    static let fps: Int32 = 30
}

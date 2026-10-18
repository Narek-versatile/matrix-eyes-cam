import Foundation
import SystemExtensions

/// Asks macOS to install (activate) the camera extension that ships inside the app bundle.
/// macOS then asks you to approve it once in System Settings.
final class ExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate {
    var onMessage: ((String) -> Void)?

    static var isBundled: Bool {
        let path = Bundle.main.bundlePath + "/Contents/Library/SystemExtensions/\(VirtualCameraID.extensionBundleID).systemextension"
        return FileManager.default.fileExists(atPath: path)
    }

    func install() {
        guard ExtensionInstaller.isBundled else {
            onMessage?("This build doesn't contain the camera extension. Build it with scripts/build-signed.sh (needs an Apple developer team, see PLAN.md).")
            return
        }
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
            onMessage?("Move Matrix Eyes Cam into your Applications folder first; macOS only installs camera extensions from there.")
            return
        }
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: VirtualCameraID.extensionBundleID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        onMessage?("Installing…")
    }

    func uninstall() {
        let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: VirtualCameraID.extensionBundleID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        onMessage?("Approve “Matrix Eyes Cam” in System Settings › General › Login Items & Extensions › Camera Extensions.")
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed: onMessage?("Installed. In Meet, choose “Matrix Eyes Cam” under Settings › Video › Camera.")
        case .willCompleteAfterReboot: onMessage?("Restart your Mac to finish installing the camera.")
        @unknown default: onMessage?("Finished.")
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        onMessage?("Couldn't install the camera: \(error.localizedDescription)")
    }
}

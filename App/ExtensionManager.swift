import Foundation
import MiradaKit
import Observation
import Security
import SystemExtensions

/// Installs Mirada's camera extension when the build is entitled to, and
/// reports honestly when it isn't (free developer teams can't).
@MainActor
@Observable
final class ExtensionManager: NSObject {
    enum Status: Equatable {
        case active
        case needsApproval
        case notInstalled
        case needsPaidTeam
        case failed(String)
    }

    static let identifier = "com.jcantor.mirada.camera"
    private(set) var status: Status = .notInstalled

    /// True when this build carries `com.apple.developer.system-extension.install`.
    static let canInstall: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.system-extension.install" as CFString, nil)
        return (value as? Bool) == true
    }()

    func refresh() {
        if VirtualCameraTarget.available().contains(.mirada) {
            status = .active
        } else if !Self.canInstall {
            status = .needsPaidTeam
        } else if status != .needsApproval {
            status = .notInstalled
        }
    }

    func install() {
        guard Self.canInstall else {
            status = .needsPaidTeam
            return
        }
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
}

extension ExtensionManager: OSSystemExtensionRequestDelegate {
    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in self.status = .needsApproval }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            self.status = result == .completed ? .active : .needsApproval
            self.refresh()
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.status = .failed(message) }
    }
}

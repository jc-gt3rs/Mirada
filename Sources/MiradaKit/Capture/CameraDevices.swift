@preconcurrency import AVFoundation

public struct CameraDeviceInfo: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let model: String
    /// Virtual cameras (Mirada's own, OBS) are listed but never used as input,
    /// so Mirada can't end up feeding its own output back into itself.
    public let isVirtual: Bool
}

public enum CameraDevices {
    static let virtualMarkers = ["Mirada", "OBS", "Virtual"]

    static func discovery() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
    }

    public static func list() -> [CameraDeviceInfo] {
        discovery().devices.map { d in
            CameraDeviceInfo(id: d.uniqueID, name: d.localizedName, model: d.modelID, isVirtual: isVirtual(name: d.localizedName, model: d.modelID))
        }
    }

    static func isVirtual(name: String, model: String) -> Bool {
        virtualMarkers.contains { name.contains($0) || model.contains($0) }
    }

    /// The requested device, or the best physical camera.
    static func device(id: String?) throws -> AVCaptureDevice {
        let devices = discovery().devices
        if let id {
            guard let d = devices.first(where: { $0.uniqueID == id || $0.localizedName == id }) else {
                throw MiradaError.cameraUnavailable("no camera with id or name \"\(id)\". Run `mirada devices`.")
            }
            return d
        }
        let physical = devices.filter { !isVirtual(name: $0.localizedName, model: $0.modelID) }
        if let builtIn = physical.first(where: { $0.deviceType == .builtInWideAngleCamera }) { return builtIn }
        if let any = physical.first { return any }
        throw MiradaError.cameraUnavailable("no physical camera found")
    }
}

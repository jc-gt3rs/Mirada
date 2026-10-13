import Foundation

public enum MiradaError: Error, Equatable, LocalizedError {
    case cameraUnavailable(String)
    case cameraPermissionDenied
    case modelMissing(String)
    case inputMissing(URL)
    case inputUnreadable(URL, String)
    case outputUnwritable(URL, String)
    case virtualCameraUnavailable(String)
    case invalidArgument(String)
    case internalError(String)

    public var errorDescription: String? {
        switch self {
        case .cameraUnavailable(let why): "camera unavailable: \(why)"
        case .cameraPermissionDenied: "camera access denied. Allow it in System Settings > Privacy & Security > Camera."
        case .modelMissing(let why): "gaze model unavailable: \(why)"
        case .inputMissing(let url): "no such file: \(url.path)"
        case .inputUnreadable(let url, let why): "can't read \(url.lastPathComponent): \(why)"
        case .outputUnwritable(let url, let why): "can't write \(url.path): \(why)"
        case .virtualCameraUnavailable(let why): "virtual camera unavailable: \(why)"
        case .invalidArgument(let why): why
        case .internalError(let why): "internal error: \(why)"
        }
    }

    /// sysexits(3) codes, so scripts can tell failures apart.
    public var exitCode: Int32 {
        switch self {
        case .invalidArgument: 64        // EX_USAGE
        case .inputUnreadable: 65        // EX_DATAERR
        case .inputMissing: 66           // EX_NOINPUT
        case .cameraUnavailable, .modelMissing, .virtualCameraUnavailable: 69 // EX_UNAVAILABLE
        case .internalError: 70          // EX_SOFTWARE
        case .outputUnwritable: 73       // EX_CANTCREAT
        case .cameraPermissionDenied: 77 // EX_NOPERM
        }
    }
}

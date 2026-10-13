import CoreMedia
import CoreMediaIO
import Foundation

/// Thin helpers over the CoreMediaIO C property API.
enum CMIO {
    static func address(_ selector: Int, scope: Int = kCMIOObjectPropertyScopeGlobal) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(scope),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    static func objects(_ owner: CMIOObjectID, _ selector: Int) -> [CMIOObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(owner, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var out = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(owner, &addr, 0, nil, size, &used, &out) == noErr else { return [] }
        return out
    }

    static func string(_ object: CMIOObjectID, _ selector: Int) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func uint32(_ object: CMIOObjectID, _ selector: Int) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, 4, &used, &value) == noErr else { return nil }
        return value
    }

    static func formatDescription(_ stream: CMIOStreamID) -> CMVideoFormatDescription? {
        var addr = address(kCMIOStreamPropertyFormatDescription)
        var value: Unmanaged<CMFormatDescription>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CMFormatDescription>?>.size)
        guard CMIOObjectGetPropertyData(stream, &addr, 0, nil, size, &used, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue()
    }

    /// Lets this process see camera extensions and screen-capture devices.
    static func allowExtensionDevices() {
        var allow: UInt32 = 1
        var addr = address(kCMIOHardwarePropertyAllowScreenCaptureDevices)
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, 4, &allow)
    }

    struct Device {
        let id: CMIOObjectID
        let name: String
        let model: String
        let streams: [(id: CMIOStreamID, isSink: Bool)]
    }

    static func devices() -> [Device] {
        allowExtensionDevices()
        return objects(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices).map { d in
            let streams = objects(d, kCMIODevicePropertyStreams).map { s in
                // Direction 0 is a stream that takes frames from clients (a sink).
                (id: s, isSink: uint32(s, kCMIOStreamPropertyDirection) == 0)
            }
            return Device(id: d, name: string(d, kCMIOObjectPropertyName) ?? "", model: string(d, kCMIODevicePropertyModelUID) ?? "", streams: streams)
        }
    }
}

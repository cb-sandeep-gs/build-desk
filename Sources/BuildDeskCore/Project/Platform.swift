import Foundation

/// The operating system a target is built for and a device runs. Used to offer only the devices a
/// scheme can be installed on.
public enum Platform: String, Sendable, Codable, CaseIterable {
    case iOS
    case watchOS
    case tvOS
    case visionOS
    case macOS

    /// From an `SDKROOT` build setting such as "iphoneos" or "watchos".
    public init?(sdkRoot: String) {
        switch sdkRoot.lowercased() {
        case let sdk where sdk.hasPrefix("iphone"): self = .iOS
        case let sdk where sdk.hasPrefix("watch"): self = .watchOS
        case let sdk where sdk.hasPrefix("appletv"): self = .tvOS
        case let sdk where sdk.hasPrefix("xr"): self = .visionOS
        case let sdk where sdk.hasPrefix("macosx"): self = .macOS
        default: return nil
        }
    }

    /// From the platform name the device tools report, such as "iOS" or "watchOS".
    public init?(deviceName: String) {
        switch deviceName.lowercased() {
        case "ios", "ipados": self = .iOS
        case "watchos": self = .watchOS
        case "tvos": self = .tvOS
        case "visionos", "xros": self = .visionOS
        case "macos": self = .macOS
        default: return nil
        }
    }
}

extension Device {
    /// Nil when the tools report a platform Build Desk does not know yet.
    public var platformKind: Platform? { Platform(deviceName: platform) }
}

extension ProjectSnapshot {
    /// The platform of the scheme's main product, when the project file states it.
    public func platform(of scheme: Scheme) -> Platform? {
        guard let main = scheme.buildTargets.first else { return nil }
        return targets.first { $0.name == main.name }?.platform
    }

    /// False only when both platforms are known and differ; an unknown platform is not a reason to
    /// hide a device.
    public func canInstall(_ scheme: Scheme, on device: Device) -> Bool {
        guard let wanted = platform(of: scheme), let offered = device.platformKind else { return true }
        return wanted == offered
    }
}

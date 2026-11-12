import Foundation

/// A place an app can be installed: a real device or a simulator.
public struct Device: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case physical
        case simulator
    }

    public enum Connection: String, Sendable, Codable {
        case wired
        case network
        /// A simulator runs on this Mac.
        case local
        /// Known to this Mac but not reachable right now.
        case none
    }

    /// The UDID. The same value is the `xcodebuild` destination id and the device argument of
    /// `devicectl` and `simctl`.
    public let id: String
    public let name: String
    /// The marketing name, such as "iPhone 17".
    public let model: String
    /// "iOS", "watchOS", "tvOS" and so on, as the tools report it.
    public let platform: String
    public let osVersion: String
    public let kind: Kind
    public let connection: Connection
    /// True when an install can start now: a real device that is reachable, or a simulator whose
    /// runtime is installed (Build Desk boots it when needed).
    public let isReady: Bool
    public let isBooted: Bool
    /// Why the device cannot take an install; nil when it can, or when nothing is known to be wrong.
    public let issue: DeviceIssue?

    public init(
        id: String,
        name: String,
        model: String,
        platform: String,
        osVersion: String,
        kind: Kind,
        connection: Connection,
        isReady: Bool,
        isBooted: Bool,
        issue: DeviceIssue? = nil
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.platform = platform
        self.osVersion = osVersion
        self.kind = kind
        self.connection = connection
        self.isReady = isReady
        self.isBooted = isBooted
        self.issue = issue
    }
}

/// What stands between a device and an install, with what to do about it.
public enum DeviceIssue: String, Sendable, Codable, CaseIterable {
    /// Known to this Mac, but not reachable by cable or network right now.
    case notConnected
    /// Connected, but the device has not been told to trust this Mac.
    case notPaired
    /// Developer Mode is off, so the device refuses apps that are not from the App Store.
    case developerModeOff
    /// The screen is locked. An install may work, but the app cannot be opened.
    case locked

    /// A few words, for a device list.
    public var title: String {
        switch self {
        case .notConnected: "not connected"
        case .notPaired: "not trusted"
        case .developerModeOff: "Developer Mode off"
        case .locked: "locked"
        }
    }

    /// What to do, as one instruction.
    public func fix(for deviceName: String) -> String {
        switch self {
        case .notConnected:
            "\(deviceName) is not connected. Connect it with a cable and unlock it."
        case .notPaired:
            "\(deviceName) doesn't trust this Mac yet. Unlock it, reconnect the cable and tap Trust."
        case .developerModeOff:
            "Developer Mode is off on \(deviceName). Turn it on in Settings ▸ Privacy & Security ▸ Developer Mode, then restart the device."
        case .locked:
            "\(deviceName) is locked. Unlock it so the app can be opened after the install."
        }
    }
}

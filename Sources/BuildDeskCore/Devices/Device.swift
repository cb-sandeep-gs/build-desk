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

    public init(
        id: String,
        name: String,
        model: String,
        platform: String,
        osVersion: String,
        kind: Kind,
        connection: Connection,
        isReady: Bool,
        isBooted: Bool
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
    }
}

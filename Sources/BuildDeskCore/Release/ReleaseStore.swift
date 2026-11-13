import Foundation

/// Live state from the store, per build: the answer of the `store` command.
public struct ReleaseStoreStatus: Sendable, Equatable, Codable {
    public let contract: Int
    /// False when the provider has no access to the store on this Mac.
    public let connected: Bool
    /// When not connected: what to do about it, in the provider's words.
    public let hint: String?
    public let apps: [ReleaseStoreApp]

    public init(contract: Int = ReleaseContract.version, connected: Bool, hint: String? = nil, apps: [ReleaseStoreApp] = []) {
        self.contract = contract
        self.connected = connected
        self.hint = hint
        self.apps = apps
    }
}

public struct ReleaseStoreApp: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let builds: [ReleaseStoreBuild]
    /// Versions on the store's side with their state, such as "Prepare for submission".
    public let storeVersions: [ReleaseStoreVersion]?
    /// Things that need attention, such as a build in the wrong tester group.
    public let alerts: [ReleaseAlert]?

    public init(id: String, builds: [ReleaseStoreBuild], storeVersions: [ReleaseStoreVersion]? = nil, alerts: [ReleaseAlert]? = nil) {
        self.id = id
        self.builds = builds
        self.storeVersions = storeVersions
        self.alerts = alerts
    }
}

/// One build as the store and the cloud build service see it.
public struct ReleaseStoreBuild: Sendable, Equatable, Codable, Identifiable {
    /// How the build's cloud run went.
    public enum Cloud: String, Sendable {
        case running
        case succeeded
        case failed
    }

    /// The same id as the build's entry in the status.
    public let id: String
    /// The store's build number.
    public let number: String?
    /// "running", "succeeded" or "failed"; anything else is shown as unknown.
    public let cloud: String?
    /// Which cloud workflow built it.
    public let cloudDetail: String?
    /// The testing state in words, such as "In testing"; nil while the build has not reached testers.
    public let testing: String?
    /// The tester groups that have the build.
    public let groups: [String]?

    public init(
        id: String, number: String? = nil, cloud: String? = nil, cloudDetail: String? = nil, testing: String? = nil,
        groups: [String]? = nil
    ) {
        self.id = id
        self.number = number
        self.cloud = cloud
        self.cloudDetail = cloudDetail
        self.testing = testing
        self.groups = groups
    }

    public var cloudState: Cloud? { cloud.flatMap(Cloud.init(rawValue:)) }
}

public struct ReleaseStoreVersion: Sendable, Equatable, Codable {
    public let version: String
    public let state: String?

    public init(version: String, state: String? = nil) {
        self.version = version
        self.state = state
    }
}

public struct ReleaseAlert: Sendable, Equatable, Codable {
    /// "error" or "warning".
    public let severity: String
    /// What happened, in one sentence.
    public let message: String
    /// What the person can do about it; nil when the provider knows no step.
    public let help: String?
    /// A web page where that step is taken.
    public let link: String?

    public init(severity: String, message: String, help: String? = nil, link: String? = nil) {
        self.severity = severity
        self.message = message
        self.help = help
        self.link = link
    }

    public var isError: Bool { severity == "error" }

    /// The link as a web address. Anything that is not http(s) is not offered: the text comes from
    /// a project's command, and only a web page may be opened from it.
    public var webPage: URL? {
        guard let link, let url = URL(string: link), let scheme = url.scheme?.lowercased(),
              ReleaseAlert.webSchemes.contains(scheme), url.host != nil else { return nil }
        return url
    }

    private static let webSchemes: Set<String> = ["https", "http"]
}

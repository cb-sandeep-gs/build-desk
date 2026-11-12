import Foundation

// The release contract: the JSON a project's own release commands print, and Build Desk reads.
// The shapes are described for providers in docs/release-contract.md.

/// Which version of the contract this Build Desk reads.
public enum ReleaseContract {
    public static let version = 1
}

/// Where each app of a project stands: the answer of the `status` command.
public struct ReleaseStatus: Sendable, Equatable, Codable {
    public let contract: Int
    public let head: ReleaseHead?
    public let apps: [ReleaseApp]
    /// Recent builds across all apps, newest first.
    public let builds: [ReleaseBuild]
    /// Branches a TestFlight build can be made from; nil when the provider only tags the checkout.
    public let branches: [String]?

    public init(
        contract: Int = ReleaseContract.version, head: ReleaseHead?, apps: [ReleaseApp], builds: [ReleaseBuild], branches: [String]? = nil
    ) {
        self.contract = contract
        self.head = head
        self.apps = apps
        self.builds = builds
        self.branches = branches
    }
}

/// The checkout the status was read from.
public struct ReleaseHead: Sendable, Equatable, Codable {
    public let branch: String?
    public let commit: String
    public let subject: String?
    /// True when tracked files differ from the commit.
    public let dirty: Bool?

    public init(branch: String?, commit: String, subject: String? = nil, dirty: Bool? = nil) {
        self.branch = branch
        self.commit = commit
        self.subject = subject
        self.dirty = dirty
    }
}

/// One app of the project (a project can ship several from one codebase).
public struct ReleaseApp: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let name: String
    /// The version in the code right now.
    public let version: String
    public let tracks: [ReleaseTrack]
    /// What is on the store; nil when nothing has been released or it is not known.
    public let store: ReleaseBuild?
    public let commitsSinceStore: Int?

    public init(
        id: String, name: String, version: String, tracks: [ReleaseTrack], store: ReleaseBuild? = nil, commitsSinceStore: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.tracks = tracks
        self.store = store
        self.commitsSinceStore = commitsSinceStore
    }
}

/// A line of test builds of an app, such as internal testers or outside partners.
public struct ReleaseTrack: Sendable, Equatable, Codable, Identifiable {
    /// How the notes of a new build on this track come about.
    public enum Notes: String, Sendable, Codable {
        /// The provider writes them, from history.
        case generated
        /// The person writes them; a new build needs notes text.
        case written
    }

    public let id: String
    public let name: String
    public let latest: ReleaseBuild?
    public let commitsSince: Int?
    public let notes: Notes?

    public init(id: String, name: String, latest: ReleaseBuild? = nil, commitsSince: Int? = nil, notes: Notes? = nil) {
        self.id = id
        self.name = name
        self.latest = latest
        self.commitsSince = commitsSince
        self.notes = notes
    }
}

/// One build that was tagged for testers or for the store.
public struct ReleaseBuild: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case testflight
        case store
    }

    /// The provider's name for the build (for example its tag), unique in the project.
    public let id: String
    public let app: String
    /// The track's id; nil for a store build.
    public let track: String?
    public let kind: Kind
    /// The version as shown to people, such as "27.05.03".
    public let version: String
    public let commit: String?
    /// Seconds since 1970.
    public let date: Double?
    public let branch: String?
    /// The first line of the build's notes.
    public let notes: String?
    /// For a store build: the test build that was shipped.
    public let from: String?

    public init(
        id: String, app: String, track: String?, kind: Kind, version: String, commit: String? = nil, date: Double? = nil,
        branch: String? = nil, notes: String? = nil, from: String? = nil
    ) {
        self.id = id
        self.app = app
        self.track = track
        self.kind = kind
        self.version = version
        self.commit = commit
        self.date = date
        self.branch = branch
        self.notes = notes
        self.from = from
    }
}

/// Something the person can ask for: a new test build, or marking a build as the store release.
public struct ReleaseAction: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case testflight
        case store
    }

    public let kind: Kind
    public let app: String
    /// For a test build: the track it goes on.
    public var track: String?
    /// For a test build: the branch to build; nil builds the checkout.
    public var branch: String?
    /// For a store release: the test build that was shipped.
    public var from: String?
    /// Notes for a track whose notes are written by hand.
    public var notes: String?

    public init(kind: Kind, app: String, track: String? = nil, branch: String? = nil, from: String? = nil, notes: String? = nil) {
        self.kind = kind
        self.app = app
        self.track = track
        self.branch = branch
        self.from = from
        self.notes = notes
    }
}

/// What an action would do: the answer of the `plan` command. Nothing has happened yet.
public struct ReleasePlan: Sendable, Equatable, Codable {
    public let contract: Int
    /// What will be created, such as the new build's name.
    public let title: String
    /// What will happen, in order, in words for the person.
    public let steps: [String]
    /// The notes the build will carry.
    public let notes: String?
    /// The commit the plan was made for. Sent back with `run`, so a plan for an older commit is refused.
    public let commit: String?
    /// Things to know before confirming.
    public let warnings: [String]?

    public init(
        contract: Int = ReleaseContract.version, title: String, steps: [String], notes: String? = nil, commit: String? = nil,
        warnings: [String]? = nil
    ) {
        self.contract = contract
        self.title = title
        self.steps = steps
        self.notes = notes
        self.commit = commit
        self.warnings = warnings
    }
}

/// What an action did: the answer of the `run` command.
public struct ReleaseResult: Sendable, Equatable, Codable {
    public let contract: Int
    /// What was created, such as the new build's name.
    public let result: String
    /// What was done, in order.
    public let done: [String]

    public init(contract: Int = ReleaseContract.version, result: String, done: [String]) {
        self.contract = contract
        self.result = result
        self.done = done
    }
}

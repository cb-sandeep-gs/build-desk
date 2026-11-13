import Foundation

/// A build's installable file on this Mac: the answer of the `artifact` command.
public struct ReleaseArtifact: Sendable, Equatable, Codable {
    public let contract: Int
    /// The absolute path of the saved file.
    public let file: String
    /// How the file was signed, in the provider's word, such as "ad-hoc".
    public let kind: String?
    public let bytes: Int64?

    public init(contract: Int = ReleaseContract.version, file: String, kind: String? = nil, bytes: Int64? = nil) {
        self.contract = contract
        self.file = file
        self.kind = kind
        self.bytes = bytes
    }

    public var url: URL { URL(fileURLWithPath: file) }
}

/// One build in full: the answer of the `build` command.
public struct ReleaseBuildDetails: Sendable, Equatable, Codable {
    public let contract: Int
    public let id: String
    /// The build's full notes, as written when it was made.
    public let notes: String?
    /// The notes testers see for the build now; nil when there are none or the store is not connected.
    public let testerNotes: String?

    public init(contract: Int = ReleaseContract.version, id: String, notes: String? = nil, testerNotes: String? = nil) {
        self.contract = contract
        self.id = id
        self.notes = notes
        self.testerNotes = testerNotes
    }
}

/// The project's go or no-go before a release: the answer of the `checks` command.
public struct ReleaseChecks: Sendable, Equatable, Codable {
    public let contract: Int
    /// True when no blocking gate failed.
    public let isGo: Bool
    public let gates: [ReleaseGate]
    /// What to do about a no-go, in the provider's words.
    public let hint: String?

    /// The contract's word is "go".
    private enum CodingKeys: String, CodingKey {
        case contract, gates, hint
        case isGo = "go"
    }

    public init(contract: Int = ReleaseContract.version, isGo: Bool, gates: [ReleaseGate], hint: String? = nil) {
        self.contract = contract
        self.isGo = isGo
        self.gates = gates
        self.hint = hint
    }
}

/// One gate of the release checks.
public struct ReleaseGate: Sendable, Equatable, Codable {
    public let title: String
    public let passed: Bool
    /// False for a gate that only advises: its failure does not make a no-go.
    public let blocking: Bool
    public let seconds: Double?

    public init(title: String, passed: Bool, blocking: Bool = true, seconds: Double? = nil) {
        self.title = title
        self.passed = passed
        self.blocking = blocking
        self.seconds = seconds
    }
}

import Foundation

/// A project's own Build Desk settings, read from a `.builddesk.json` file checked in beside the
/// project, so everyone on a team opens it with the same setup.
public struct ProjectConfig: Sendable, Equatable, Codable {
    public static let fileName = ".builddesk.json"

    /// Schemes listed first, in this order, in a group of their own.
    public var favoriteSchemes: [String]
    /// Schemes left out of the list. `*` stands for any run of characters, as in "*Tests".
    public var hiddenSchemes: [String]
    /// The scheme selected when a person opens the project for the first time.
    public var defaultScheme: String?
    /// The configuration selected when a person opens the project for the first time.
    public var defaultConfiguration: String?
    /// The project's release commands; nil means the project has no Release mode.
    public var release: ReleaseCommands?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case favoriteSchemes
        case hiddenSchemes
        case defaultScheme
        case defaultConfiguration
        case release
    }

    public init(
        favoriteSchemes: [String] = [],
        hiddenSchemes: [String] = [],
        defaultScheme: String? = nil,
        defaultConfiguration: String? = nil,
        release: ReleaseCommands? = nil
    ) {
        self.favoriteSchemes = favoriteSchemes
        self.hiddenSchemes = hiddenSchemes
        self.defaultScheme = defaultScheme
        self.defaultConfiguration = defaultConfiguration
        self.release = release
    }

    /// Every key is optional, so a file can set one thing and leave the rest alone.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        favoriteSchemes = try values.decodeIfPresent([String].self, forKey: .favoriteSchemes) ?? []
        hiddenSchemes = try values.decodeIfPresent([String].self, forKey: .hiddenSchemes) ?? []
        defaultScheme = try values.decodeIfPresent(String.self, forKey: .defaultScheme)
        defaultConfiguration = try values.decodeIfPresent(String.self, forKey: .defaultConfiguration)
        release = try values.decodeIfPresent(ReleaseCommands.self, forKey: .release)
    }

    public func hides(_ scheme: String) -> Bool {
        hiddenSchemes.contains { Self.matches(scheme, pattern: $0) }
    }

    /// Whole-name match where `*` in the pattern matches any run of characters.
    static func matches(_ name: String, pattern: String) -> Bool {
        let pieces = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count > 1 else { return name == pattern }
        guard name.hasPrefix(pieces[0]), name.hasSuffix(pieces[pieces.count - 1]),
              name.count >= pieces[0].count + pieces[pieces.count - 1].count else { return false }
        // The middle pieces must appear in order between the fixed start and end.
        var rest = name.dropFirst(pieces[0].count).dropLast(pieces[pieces.count - 1].count)
        for piece in pieces.dropFirst().dropLast() where !piece.isEmpty {
            guard let range = rest.range(of: piece) else { return false }
            rest = rest[range.upperBound...]
        }
        return true
    }
}

/// The commands of a project's release workflow, each an argument list run from the folder that
/// holds the settings file. Only `status` is required; the others add what they name.
public struct ReleaseCommands: Sendable, Equatable, Codable {
    /// Prints where each app stands. Read-only.
    public var status: [String]
    /// Prints what an action would do. Changes nothing.
    public var plan: [String]?
    /// Does what a confirmed plan described.
    public var run: [String]?
    /// Prints the go or no-go gates.
    public var checks: [String]?
    /// Prints live state from the store.
    public var store: [String]?

    public init(status: [String], plan: [String]? = nil, run: [String]? = nil, checks: [String]? = nil, store: [String]? = nil) {
        self.status = status
        self.plan = plan
        self.run = run
        self.checks = checks
        self.store = store
    }
}

/// Finds and reads a project's `.builddesk.json`.
public enum ProjectConfigLoader {
    /// What was found: the settings, and what is wrong with the file when it could not be used.
    public struct Result: Sendable, Equatable {
        public let config: ProjectConfig
        /// Nil when the project has no config file.
        public let fileURL: URL?
        /// Why the file was ignored or partly ignored, in words for the user.
        public let problem: String?
    }

    /// Folder levels searched above the project. A project sits a few folders inside its repository
    /// at most; the search also stops at the repository root.
    static let searchDepth = 6
    private static let repositoryMarker = ".git"

    /// Looks beside the project, then in each folder above it up to the repository root. A broken
    /// file never stops a project from opening: defaults are used and the problem is reported.
    public static func load(for container: ProjectContainer) -> Result {
        guard let url = fileURL(for: container) else { return Result(config: ProjectConfig(), fileURL: nil, problem: nil) }
        do {
            let data = try Data(contentsOf: url)
            let config = try JSONDecoder().decode(ProjectConfig.self, from: data)
            return Result(config: config, fileURL: url, problem: unknownKeysProblem(in: data))
        } catch {
            let reason = (error as? DecodingError).map(describe) ?? error.localizedDescription
            return Result(config: ProjectConfig(), fileURL: url, problem: "\(ProjectConfig.fileName) can't be used: \(reason)")
        }
    }

    static func fileURL(for container: ProjectContainer) -> URL? {
        var folder = container.url.deletingLastPathComponent()
        for _ in 0..<searchDepth {
            let candidate = folder.appendingPathComponent(ProjectConfig.fileName)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            // The repository root is as far as a project's own settings can live.
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(repositoryMarker).path) { return nil }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { return nil }
            folder = parent
        }
        return nil
    }

    /// A misspelt key would otherwise be silently ignored.
    private static func unknownKeysProblem(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let known = Set(ProjectConfig.CodingKeys.allCases.map(\.rawValue))
        let unknown = object.keys.filter { !known.contains($0) }.sorted()
        guard !unknown.isEmpty else { return nil }
        return "\(ProjectConfig.fileName) has keys Build Desk doesn't know: \(unknown.joined(separator: ", ")). "
            + "Known keys: \(known.sorted().joined(separator: ", "))."
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            let key = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "\(key.isEmpty ? "the file" : key) has the wrong kind of value."
        case .dataCorrupted:
            return "it is not valid JSON."
        default:
            return error.localizedDescription
        }
    }
}

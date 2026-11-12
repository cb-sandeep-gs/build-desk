import Foundation

/// One finished run, kept so the app can show what was built when, how long it took and what
/// it found.
public struct RunRecord: Sendable, Equatable, Codable, Identifiable {
    public enum Action: String, Sendable, Codable {
        case buildAndInstall
        case buildOnly
        case installOnly
    }

    public enum Result: String, Sendable, Codable {
        case succeeded
        case failed
        case stopped
    }

    public let id: UUID
    public let date: Date
    /// The path of the project or workspace, which is what records are grouped by.
    public let projectPath: String
    public let scheme: String
    public let configuration: String
    public let deviceName: String
    public let deviceKind: Device.Kind
    public let action: Action
    public let result: Result
    public let totalSeconds: Double
    /// Nil for a run that did not build.
    public let buildSeconds: Double?
    public let taskCount: Int
    public let warningCount: Int
    /// Warnings not seen in any earlier build of this scheme and configuration; nil when there is
    /// nothing to compare with (a first build, or a run that did not build).
    public let newWarningCount: Int?
    public let errorCount: Int
    /// Branch and commit the run was made from; nil outside a git checkout.
    public let source: SourceState?

    public init(
        id: UUID = UUID(),
        date: Date,
        projectPath: String,
        scheme: String,
        configuration: String,
        deviceName: String,
        deviceKind: Device.Kind,
        action: Action,
        result: Result,
        totalSeconds: Double,
        buildSeconds: Double?,
        taskCount: Int,
        warningCount: Int,
        newWarningCount: Int?,
        errorCount: Int,
        source: SourceState?
    ) {
        self.id = id
        self.date = date
        self.projectPath = projectPath
        self.scheme = scheme
        self.configuration = configuration
        self.deviceName = deviceName
        self.deviceKind = deviceKind
        self.action = action
        self.result = result
        self.totalSeconds = totalSeconds
        self.buildSeconds = buildSeconds
        self.taskCount = taskCount
        self.warningCount = warningCount
        self.newWarningCount = newWarningCount
        self.errorCount = errorCount
        self.source = source
    }
}

extension Diagnostic {
    /// What makes a warning "the same warning" from one build to the next: its file and message.
    /// The line and column are left out, because they move whenever code above them changes.
    public var fingerprint: String { "\(file ?? "")|\(message)" }
}

/// Works out which warnings of a build are new.
public enum WarningDiff {
    /// The key known warnings are kept under: one set per project, scheme and configuration.
    public static func key(projectPath: String, scheme: String, configuration: String) -> String {
        [projectPath, scheme, configuration].joined(separator: "|")
    }

    /// Warnings whose fingerprint is not among the known ones, each once.
    public static func newWarnings(in warnings: [Diagnostic], known: Set<String>) -> [Diagnostic] {
        var seen = known
        return warnings.filter { seen.insert($0.fingerprint).inserted }
    }
}

/// Keeps run records and the warnings already seen.
public protocol RunHistoryStoring: Sendable {
    /// Newest first.
    func records(forProject projectPath: String) async -> [RunRecord]
    func append(_ record: RunRecord) async
    /// Fingerprints of every warning seen so far for the key; nil before the first build.
    func knownWarnings(for key: String) async -> Set<String>?
    /// Adds to the known set. It only grows: an incremental build prints warnings only for the
    /// files it recompiled, so a warning missing from one build is not a warning that was fixed.
    func addKnownWarnings(_ fingerprints: Set<String>, for key: String) async
}

/// History in memory only: for tests, the demo and snapshots.
public actor MemoryRunHistoryStore: RunHistoryStoring {
    private var records: [RunRecord]
    private var known: [String: Set<String>] = [:]

    public init(records: [RunRecord] = []) {
        self.records = records
    }

    public func records(forProject projectPath: String) -> [RunRecord] {
        records.filter { $0.projectPath == projectPath }.sorted { $0.date > $1.date }
    }

    public func append(_ record: RunRecord) {
        records.append(record)
    }

    public func knownWarnings(for key: String) -> Set<String>? { known[key] }

    public func addKnownWarnings(_ fingerprints: Set<String>, for key: String) {
        known[key, default: []].formUnion(fingerprints)
    }
}

/// History in two small JSON files in the app's support folder.
public actor FileRunHistoryStore: RunHistoryStoring {
    /// Records kept across all projects; the oldest are dropped beyond this.
    public static let recordLimit = 500
    /// Warnings remembered per scheme and configuration. Far above any real project; it only
    /// stops a runaway build from growing the file without end.
    public static let knownWarningLimit = 20_000

    private static let recordsFile = "history.json"
    private static let warningsFile = "known-warnings.json"

    private let directory: URL
    private var records: [RunRecord]?
    private var known: [String: Set<String>]?

    /// `~/Library/Application Support/BuildDesk`.
    public static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(BuildDeskConstants.Logs.folderName)
    }

    public init(directory: URL) {
        self.directory = directory
    }

    public func records(forProject projectPath: String) -> [RunRecord] {
        loadedRecords().filter { $0.projectPath == projectPath }.sorted { $0.date > $1.date }
    }

    public func append(_ record: RunRecord) {
        let all = Array((loadedRecords() + [record]).suffix(Self.recordLimit))
        records = all
        save(all, to: Self.recordsFile)
    }

    public func knownWarnings(for key: String) -> Set<String>? { loadedKnown()[key] }

    public func addKnownWarnings(_ fingerprints: Set<String>, for key: String) {
        var all = loadedKnown()
        let merged = all[key, default: []].union(fingerprints)
        // Sorted before trimming, so which ones are kept does not depend on set order.
        all[key] = merged.count > Self.knownWarningLimit ? Set(merged.sorted().prefix(Self.knownWarningLimit)) : merged
        known = all
        save(all.mapValues { $0.sorted() }, to: Self.warningsFile)
    }

    private func loadedRecords() -> [RunRecord] {
        if let records { return records }
        let loaded: [RunRecord] = load(Self.recordsFile) ?? []
        records = loaded
        return loaded
    }

    private func loadedKnown() -> [String: Set<String>] {
        if let known { return known }
        let loaded: [String: [String]] = load(Self.warningsFile) ?? [:]
        let sets = loaded.mapValues(Set.init)
        known = sets
        return sets
    }

    /// A missing or damaged file is an empty history, never an error: history is a convenience.
    private func load<T: Decodable>(_ file: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(file)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    private func save(_ value: some Encodable, to file: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Atomic, so a crash mid-write cannot leave half a file.
        try? data.write(to: directory.appendingPathComponent(file), options: .atomic)
    }
}

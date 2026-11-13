import Foundation

/// A copy of a project at one commit, kept in Build Desk's own folder.
public struct TaggedSource: Sendable, Equatable {
    /// The project file inside the copy.
    public let container: ProjectContainer
    /// The copy's top folder.
    public let folder: URL
    /// The full hash of the commit the copy is on.
    public let commit: String
    /// Size of the copy on disk; nil when it was not measured.
    public let bytes: Int64?

    public init(container: ProjectContainer, folder: URL, commit: String, bytes: Int64? = nil) {
        self.container = container
        self.folder = folder
        self.commit = commit
        self.bytes = bytes
    }
}

/// Makes a project's code at another commit available to build, without touching the checkout
/// the person works in.
public protocol TaggedSourcePreparing: Sendable {
    /// The project at `commit`. One copy per repository is kept and moved from commit to commit, so
    /// the second build from it is an incremental one.
    func prepare(commit: String, of container: ProjectContainer) async throws -> TaggedSource
    /// The copy made earlier for this project, with its size; nil when there is none.
    func existing(for container: ProjectContainer) async -> TaggedSource?
    /// Deletes the copy. The caller asks the person first.
    func remove(_ source: TaggedSource) async throws
}

/// Keeps the copy as a git clone that borrows the objects of the person's repository
/// (`git clone --shared`), so making it copies no history. Every git command that changes
/// something runs inside the copy; the person's repository is only read.
public struct TaggedCheckout: TaggedSourcePreparing {
    private let toolRunner: any ToolRunning
    private let root: URL

    /// - Parameter root: where copies are kept; nil is Build Desk's folder in the user's caches.
    public init(toolRunner: any ToolRunning = ProcessToolRunner(), root: URL? = nil) {
        self.toolRunner = toolRunner
        self.root = root ?? Self.defaultRoot
    }

    static var defaultRoot: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent(BuildDeskConstants.Logs.folderName)
            .appendingPathComponent(BuildDeskConstants.TaggedSources.folderName)
    }

    public func prepare(commit: String, of container: ProjectContainer) async throws -> TaggedSource {
        let repository = try await repositoryRoot(of: container)
        // The full hash, and proof that this Mac has the commit at all.
        let verify = try await toolRunner.run(AppleTools.git(in: repository, ["rev-parse", "--verify", "--quiet", "\(commit)^{commit}"]))
        let full = Self.text(verify.stdout)
        guard verify.succeeded, !full.isEmpty else {
            throw BuildDeskError.taggedSourceFailed(
                message: "This Mac doesn't have commit \(commit.prefix(BuildDeskConstants.TaggedSources.shortCommitLength)) yet. "
                    + "Fetch the project's tags, then try again."
            )
        }
        let folder = slot(for: repository)
        if !FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let clone = ["clone", "--shared", "--no-checkout", "--quiet", repository.path, folder.path]
            try await git(in: root, clone, doing: "copy the project")
        }
        // Files the commit does not change keep their dates, so the next build is incremental.
        try await git(in: folder, ["checkout", "--force", "--detach", "--quiet", full], doing: "switch the copy to the commit")
        return TaggedSource(container: try self.container(in: folder, matching: container, of: repository), folder: folder, commit: full)
    }

    public func existing(for container: ProjectContainer) async -> TaggedSource? {
        guard let repository = try? await repositoryRoot(of: container) else { return nil }
        let folder = slot(for: repository)
        guard FileManager.default.fileExists(atPath: folder.path),
              let head = try? await toolRunner.run(AppleTools.git(in: folder, ["rev-parse", "HEAD"])), head.succeeded,
              let copy = try? self.container(in: folder, matching: container, of: repository) else { return nil }
        let bytes = await DiskUsage.bytes(of: folder, toolRunner: toolRunner)
        return TaggedSource(container: copy, folder: folder, commit: Self.text(head.stdout), bytes: bytes)
    }

    public func remove(_ source: TaggedSource) async throws {
        // Only ever a folder directly inside this service's own root.
        guard source.folder.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else {
            throw CocoaError(.fileWriteNoPermission)
        }
        guard FileManager.default.fileExists(atPath: source.folder.path) else { return }
        try FileManager.default.removeItem(at: source.folder)
    }

    // MARK: - Parts

    private func repositoryRoot(of container: ProjectContainer) async throws -> URL {
        let folder = container.url.deletingLastPathComponent()
        let result = try await toolRunner.run(AppleTools.git(in: folder, ["rev-parse", "--show-toplevel"]))
        let path = Self.text(result.stdout)
        guard result.succeeded, !path.isEmpty else {
            throw BuildDeskError.taggedSourceFailed(
                message: "\(container.name) is not in a git checkout, so there is no tagged code to build."
            )
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }

    /// One folder per repository: its name, plus a short hash of its path to keep two
    /// repositories of the same name apart.
    func slot(for repository: URL) -> URL {
        // Always a folder, so the URL is the same before and after it exists.
        root.appendingPathComponent("\(repository.lastPathComponent)-\(Self.shortHash(of: repository.path))", isDirectory: true)
    }

    /// The same project file, at the same place inside the copy.
    private func container(in folder: URL, matching container: ProjectContainer, of repository: URL) throws -> ProjectContainer {
        let original = container.url.resolvingSymlinksInPath().path
        let prefix = repository.path + "/"
        guard original.hasPrefix(prefix) else {
            throw BuildDeskError.taggedSourceFailed(message: "\(container.name) is not inside its git checkout.")
        }
        return try ProjectContainer(url: folder.appendingPathComponent(String(original.dropFirst(prefix.count))))
    }

    private func git(in folder: URL, _ arguments: [String], doing what: String) async throws {
        let result = try await toolRunner.run(AppleTools.git(in: folder, arguments))
        guard result.succeeded else {
            let reason = Self.text(result.stderr)
            throw BuildDeskError.taggedSourceFailed(message: "Couldn't \(what). \(reason)")
        }
    }

    private static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// FNV-1a: the same text gives the same hash on every launch, which Swift's own hashing does not.
    static func shortHash(of text: String) -> String {
        let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        let hash = text.utf8.reduce(offsetBasis) { ($0 ^ UInt64($1)) &* prime }
        return String(hash, radix: 16).prefix(BuildDeskConstants.TaggedSources.hashLength).description
    }
}

import Foundation

/// Where a checkout stands: shown next to an install so it is clear which code is on the device.
public struct SourceState: Sendable, Equatable, Codable {
    public let branch: String
    /// The short commit hash.
    public let commit: String
    /// True when tracked files differ from that commit, so the build is not exactly the commit.
    public let hasLocalChanges: Bool

    public init(branch: String, commit: String, hasLocalChanges: Bool) {
        self.branch = branch
        self.commit = commit
        self.hasLocalChanges = hasLocalChanges
    }
}

/// Reads the branch and commit of the checkout a project is in. Read-only: it never changes the
/// checkout.
public struct SourceStateReader: Sendable {
    private let toolRunner: any ToolRunning

    public init(toolRunner: any ToolRunning = ProcessToolRunner()) {
        self.toolRunner = toolRunner
    }

    public func state(of folder: URL) async -> SourceState? {
        guard let branch = await output(of: ["rev-parse", "--abbrev-ref", "HEAD"], in: folder),
              let commit = await output(of: ["rev-parse", "--short", "HEAD"], in: folder) else { return nil }
        // Untracked files are left out: they are common (notes, build output) and slow to scan.
        let changes = await output(of: ["status", "--porcelain", "--untracked-files=no"], in: folder)
        return SourceState(branch: branch, commit: commit, hasLocalChanges: !(changes ?? "").isEmpty)
    }

    /// The trimmed output of a git command, or nil when it failed (not a checkout, no git).
    private func output(of arguments: [String], in folder: URL) async -> String? {
        guard let result = try? await toolRunner.run(AppleTools.git(in: folder, arguments)), result.succeeded else { return nil }
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

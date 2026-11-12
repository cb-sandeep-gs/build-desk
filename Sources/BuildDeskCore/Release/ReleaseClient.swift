import Foundation

/// A project's release workflow, as Build Desk sees it.
public protocol ReleaseProviding: Sendable {
    /// Where each app stands. Read-only.
    func status(_ provider: ReleaseProvider) async throws -> ReleaseStatus
    /// What an action would do. Changes nothing.
    func plan(_ action: ReleaseAction, _ provider: ReleaseProvider) async throws -> ReleasePlan
    /// Does what the plan described. Call only after the person has confirmed that plan.
    func run(_ action: ReleaseAction, confirming plan: ReleasePlan, _ provider: ReleaseProvider) async throws -> ReleaseResult
}

/// The commands a project supplies, and the folder they are run from.
public struct ReleaseProvider: Sendable, Equatable {
    public let commands: ReleaseCommands
    /// The folder that holds the project's `.builddesk.json`; relative commands start here.
    public let folder: URL

    public init(commands: ReleaseCommands, folder: URL) {
        self.commands = commands
        self.folder = folder
    }
}

/// Runs a project's release commands and reads their JSON.
public struct ReleaseClient: ReleaseProviding {
    /// Flags Build Desk adds to a provider's `plan` and `run` commands.
    enum Flag {
        static let action = "--action"
        static let app = "--app"
        static let track = "--track"
        static let branch = "--branch"
        static let from = "--from"
        static let notesFile = "--notes-file"
        static let expect = "--expect"
    }

    private static let environmentTool = "/usr/bin/env"

    private let toolRunner: any ToolRunning

    public init(toolRunner: any ToolRunning = ProcessToolRunner()) {
        self.toolRunner = toolRunner
    }

    public func status(_ provider: ReleaseProvider) async throws -> ReleaseStatus {
        let status: ReleaseStatus = try await answer(of: provider.commands.status, [], provider, name: "status")
        try Self.checkVersion(status.contract)
        return status
    }

    public func plan(_ action: ReleaseAction, _ provider: ReleaseProvider) async throws -> ReleasePlan {
        guard let command = provider.commands.plan else { throw BuildDeskError.releaseCommandMissing(name: "plan") }
        return try await withNotesFile(action.notes) { notesFile in
            let plan: ReleasePlan = try await answer(of: command, Self.arguments(for: action, notesFile: notesFile), provider, name: "plan")
            try Self.checkVersion(plan.contract)
            return plan
        }
    }

    public func run(_ action: ReleaseAction, confirming plan: ReleasePlan, _ provider: ReleaseProvider) async throws -> ReleaseResult {
        guard let command = provider.commands.run else { throw BuildDeskError.releaseCommandMissing(name: "run") }
        return try await withNotesFile(action.notes) { notesFile in
            var arguments = Self.arguments(for: action, notesFile: notesFile)
            // The provider refuses when the code moved since the plan was shown.
            if let commit = plan.commit { arguments += [Flag.expect, commit] }
            return try await answer(of: command, arguments, provider, name: "run")
        }
    }

    static func arguments(for action: ReleaseAction, notesFile: URL?) -> [String] {
        var arguments = [Flag.action, action.kind.rawValue, Flag.app, action.app]
        if let track = action.track { arguments += [Flag.track, track] }
        if let branch = action.branch, !branch.isEmpty { arguments += [Flag.branch, branch] }
        if let from = action.from { arguments += [Flag.from, from] }
        if let notesFile { arguments += [Flag.notesFile, notesFile.path] }
        return arguments
    }

    /// Notes travel as a file, so their text never has to fit on a command line.
    private func withNotesFile<T>(_ notes: String?, _ work: (URL?) async throws -> T) async throws -> T {
        guard let notes, !notes.isEmpty else { return try await work(nil) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("builddesk-notes-\(UUID().uuidString).txt")
        try Data(notes.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return try await work(file)
    }

    private func answer<T: Decodable>(of argv: [String], _ extra: [String], _ provider: ReleaseProvider, name: String) async throws -> T {
        guard let first = argv.first else { throw BuildDeskError.releaseCommandMissing(name: name) }
        // "./tool" is the project's own, relative to the settings file's folder; a bare name such
        // as "python3" is found through the PATH.
        let command: ToolCommand
        if first.contains("/") {
            let tool = first.hasPrefix("/") ? URL(fileURLWithPath: first) : provider.folder.appendingPathComponent(first)
            command = ToolCommand(
                executable: tool.standardizedFileURL.path, arguments: Array(argv.dropFirst()) + extra, workingDirectory: provider.folder
            )
        } else {
            command = ToolCommand(executable: Self.environmentTool, arguments: argv + extra, workingDirectory: provider.folder)
        }
        let result = try await toolRunner.run(command)

        // A provider reports a failure as JSON too; its words are better than the exit code.
        if let failure = try? JSONDecoder().decode(ProviderFailure.self, from: result.stdout) {
            throw BuildDeskError.releaseFailed(message: failure.error)
        }
        guard result.succeeded else {
            throw BuildDeskError.releaseFailed(message: result.failureTail())
        }
        do {
            return try JSONDecoder().decode(T.self, from: result.stdout)
        } catch {
            throw BuildDeskError.unexpectedOutput(tool: "the release \(name) command", reason: error.localizedDescription)
        }
    }

    private static func checkVersion(_ version: Int) throws {
        guard version == ReleaseContract.version else {
            let message = "The project speaks release contract \(version); this Build Desk reads \(ReleaseContract.version). "
                + "Update Build Desk."
            throw BuildDeskError.releaseFailed(message: message)
        }
    }

    private struct ProviderFailure: Decodable {
        let error: String
    }
}

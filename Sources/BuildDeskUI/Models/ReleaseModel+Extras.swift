import BuildDeskCore
import Foundation

/// A build's installable file being fetched, or how that ended.
public struct ReleaseDownload: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case running
        case done(URL)
        case failed(String)
    }

    public let buildID: String
    public internal(set) var phase: Phase
}

extension ReleaseModel {
    // MARK: - The build's file

    /// True when the project can hand out this build's file: it has the command, and the cloud build succeeded.
    public func canDownload(_ build: ReleaseBuild) -> Bool {
        provider.commands.artifact != nil && storeBuild(for: build)?.cloudState == .succeeded
    }

    /// The download of this build, when it is the one last asked for.
    public func download(of build: ReleaseBuild) -> ReleaseDownload? {
        download?.buildID == build.id ? download : nil
    }

    /// Saves the build's file into the downloads folder. A file already there is reused by the provider.
    public func downloadArtifact(of build: ReleaseBuild) async {
        guard canDownload(build), download?.phase != .running else { return }
        download = ReleaseDownload(buildID: build.id, phase: .running)
        do {
            let artifact = try await client.artifact(of: build, to: downloadsFolder, provider)
            download?.phase = .done(artifact.url)
        } catch {
            download?.phase = .failed(userMessage(for: error))
        }
    }

    // MARK: - A build in full

    /// Reads a build's full notes and the notes testers see now. Asked once per build; a project
    /// without the command, or a failure, leaves what the status said.
    @discardableResult
    public func loadDetails(of build: ReleaseBuild, refreshing: Bool = false) async -> ReleaseBuildDetails? {
        guard provider.commands.build != nil else { return nil }
        if !refreshing, let known = details[build.id] { return known }
        guard let fresh = try? await client.details(of: build, provider) else { return details[build.id] }
        details[build.id] = fresh
        return fresh
    }

    /// The notes to show for a build: all of them once read, else the first line the status has.
    public func notes(of build: ReleaseBuild) -> String? {
        details[build.id]?.notes ?? build.notes
    }

    // MARK: - Actions on an existing build

    /// True when this action can be offered for the build: the project has it, can run it, and the
    /// store knows the build.
    public func offers(_ kind: ReleaseAction.Kind, for build: ReleaseBuild) -> Bool {
        guard kind.isBuildAction, canAct, build.kind == .testflight, storeBuild(for: build)?.cloudState == .succeeded else { return false }
        return status?.buildActions?.contains(kind.rawValue) == true
    }

    /// Starts an action on an existing build. Nothing happens until its plan is confirmed.
    public func begin(_ kind: ReleaseAction.Kind, for build: ReleaseBuild) {
        guard offers(kind, for: build), activeAction == nil, let app = status?.apps.first(where: { $0.id == build.app }),
              let status else { return }
        let model = ReleaseActionModel(kind: kind, build: build, app: app, status: status, provider: provider, client: client)
        activeAction = model
        switch kind {
        // Adding to testers has nothing to fill in: show what would happen at once.
        case .testers: Task { await model.preview() }
        // Editing starts from what testers see now, read fresh; else from the build's own notes.
        case .notes: Task { await prefillNotes(of: build, in: model) }
        case .testflight, .store: break
        }
    }

    /// Puts the current notes into the editor, unless the person has already started typing.
    func prefillNotes(of build: ReleaseBuild, in model: ReleaseActionModel) async {
        guard provider.commands.build != nil else { return }
        model.isLoadingNotes = true
        let current = await loadDetails(of: build, refreshing: true)
        model.isLoadingNotes = false
        guard activeAction === model, (model.action.notes ?? "").isEmpty else { return }
        if let text = current?.testerNotes ?? current?.notes, !text.isEmpty { model.action.notes = text }
    }

    /// After notes were saved: what testers see has changed, so the next look reads it again.
    func forgetDetails(of buildID: String) {
        details[buildID] = nil
    }

    // MARK: - Checks

    /// True when the project has go or no-go gates to run.
    public var hasChecks: Bool { provider.commands.checks != nil }

    /// Runs the project's gates. They read and compare; nothing is changed.
    public func runChecks() async {
        guard hasChecks, checks != .loading else { return }
        checks = .loading
        do {
            checks = .loaded(try await client.checks(provider))
        } catch {
            checks = .failed(userMessage(for: error))
        }
    }
}

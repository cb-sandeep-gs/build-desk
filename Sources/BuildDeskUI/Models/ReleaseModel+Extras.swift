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
        // Adding to testers has nothing to fill in: show what would happen at once.
        if kind == .testers { Task { await model.preview() } }
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

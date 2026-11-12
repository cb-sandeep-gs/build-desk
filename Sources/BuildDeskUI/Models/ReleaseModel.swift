import BuildDeskCore
import Foundation
import Observation

/// What the main window shows for a project that has release commands.
public enum WindowMode: String, Sendable, CaseIterable {
    case build
    case release

    public var title: String {
        switch self {
        case .build: "Build"
        case .release: "Release"
        }
    }
}

/// Where each app of the open project stands, read from the project's own release commands.
@MainActor
@Observable
public final class ReleaseModel {
    public let provider: ReleaseProvider
    public private(set) var state: LoadState<ReleaseStatus> = .idle
    /// True while a refresh is running over a status that is already shown.
    public private(set) var isRefreshing = false
    public var selectedAppID: String?
    /// The build whose details are open; nil when none is.
    public var selectedBuildID: String?
    /// The release action in progress, shown as a sheet; nil when none is.
    public internal(set) var activeAction: ReleaseActionModel?

    private let client: any ReleaseProviding

    public init(provider: ReleaseProvider, client: any ReleaseProviding) {
        self.provider = provider
        self.client = client
    }

    public var status: ReleaseStatus? { state.value }

    public var selectedApp: ReleaseApp? {
        status?.apps.first { $0.id == selectedAppID }
    }

    /// Recent builds of the selected app, newest first.
    public var builds: [ReleaseBuild] {
        (status?.builds ?? []).filter { $0.app == selectedAppID }
    }

    /// True when the project's commands can do something, not only show it.
    public var canAct: Bool {
        provider.commands.plan != nil && provider.commands.run != nil
    }

    /// Reads the status. The status on screen stays while a newer one is fetched.
    public func refresh() async {
        guard !isRefreshing else { return }
        if status == nil { state = .loading }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fresh = try await client.status(provider)
            state = .loaded(fresh)
            // Keep the person's app if it is still there; else start on the first.
            if !fresh.apps.contains(where: { $0.id == selectedAppID }) { selectedAppID = fresh.apps.first?.id }
            if !fresh.builds.contains(where: { $0.id == selectedBuildID }) { selectedBuildID = nil }
        } catch {
            state = .failed(userMessage(for: error))
        }
    }

    /// Starts a release action for the selected app. Nothing happens until its plan is confirmed.
    public func begin(_ kind: ReleaseAction.Kind) {
        guard canAct, activeAction == nil, let app = selectedApp, let status else { return }
        activeAction = ReleaseActionModel(kind: kind, app: app, status: status, provider: provider, client: client)
    }

    /// Closes the action. After one that ran, the status is read again to show the new build.
    public func endAction() async {
        let ran = activeAction?.isDone == true
        activeAction = nil
        if ran { await refresh() }
    }

    /// The track's name for a build of the selected app; "Store" for a store build.
    public func trackName(of build: ReleaseBuild) -> String {
        guard build.kind == .testflight else { return "Store" }
        let app = status?.apps.first { $0.id == build.app }
        return app?.tracks.first { $0.id == build.track }?.name ?? build.track ?? "Test build"
    }
}

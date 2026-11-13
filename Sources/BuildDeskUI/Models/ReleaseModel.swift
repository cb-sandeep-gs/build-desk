import BuildDeskCore
import Foundation
import Observation

/// What the main window shows for a project that has release commands.
public enum WindowMode: String, Sendable, CaseIterable {
    case build
    case release
    /// Past runs and the files Build Desk keeps on disk.
    case activity

    public var title: String {
        switch self {
        case .build: "Build"
        case .release: "Release"
        case .activity: "Activity"
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
    /// Live state from the store. It arrives after the status, because it needs the network.
    public private(set) var store: LoadState<ReleaseStoreStatus> = .idle
    public var selectedAppID: String?
    /// The build whose details are open; nil when none is.
    public var selectedBuildID: String?
    /// Which builds the table shows.
    public var filter: ReleaseBuildFilter = .all
    /// The release action in progress, shown as a sheet; nil when none is.
    public internal(set) var activeAction: ReleaseActionModel?

    /// The build file last asked for; nil when none was.
    public internal(set) var download: ReleaseDownload?
    /// The project's go or no-go gates, once they were run.
    public internal(set) var checks: LoadState<ReleaseChecks> = .idle
    /// True while the checks sheet is open.
    public var showsChecks = false

    // Internal, not private: the model's features are split across files as extensions.
    let client: any ReleaseProviding
    /// Where a build's file is saved.
    let downloadsFolder: URL

    public init(provider: ReleaseProvider, client: any ReleaseProviding, downloadsFolder: URL? = nil) {
        self.provider = provider
        self.client = client
        self.downloadsFolder = downloadsFolder
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
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
            return
        }
        await refreshStore()
    }

    /// True when the project has a command for live store state.
    public var hasStore: Bool { provider.commands.store != nil }

    /// Reads the live store state. The status stays usable while this is in flight or if it fails.
    private func refreshStore() async {
        guard hasStore else { return }
        if store.value == nil { store = .loading }
        do {
            store = .loaded(try await client.store(provider))
        } catch {
            store = .failed(userMessage(for: error))
        }
    }

    /// What the store knows about a build; nil while not loaded, not connected or not listed there.
    public func storeBuild(for build: ReleaseBuild) -> ReleaseStoreBuild? {
        store.value?.apps.first { $0.id == build.app }?.builds.first { $0.id == build.id }
    }

    /// The selected app as the store sees it.
    public var storeApp: ReleaseStoreApp? {
        store.value?.apps.first { $0.id == selectedAppID }
    }

    /// One line on the store connection when it is not simply working; nil when there is nothing to say.
    public var storeNote: String? {
        switch store {
        case .idle: nil
        case .loading: "Reading the live store state…"
        case .failed(let message): "Couldn't read the store: \(message)"
        case .loaded(let status): status.connected ? nil : "Store not connected. \(status.hint ?? "")"
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

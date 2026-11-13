import BuildDeskCore
import Foundation
import Observation

/// One app's line in the menu bar: its version and where its newest build stands.
public struct ReleaseMenuLine: Identifiable, Equatable, Sendable {
    public enum Mark: Sendable, Equatable {
        case running
        case succeeded
        case failed
        case none
    }

    /// The app's id.
    public let id: String
    /// "Harbor 4.2".
    public let title: String
    /// "HarborInternal-4.2.3 · Building in the cloud".
    public let detail: String
    public let mark: Mark
}

extension ReleaseStoreBuild {
    /// The testing state once the build reached testers; before that, how its cloud build is going.
    var stateText: String {
        if let testing { return testing }
        switch cloudState {
        case .running: return "Building in the cloud"
        case .failed: return "Cloud build failed"
        case .succeeded: return "Built"
        case nil: return ""
        }
    }

    var menuMark: ReleaseMenuLine.Mark {
        switch cloudState {
        case .running: .running
        case .succeeded: .succeeded
        case .failed: .failed
        case nil: .none
        }
    }
}

extension ReleaseModel {
    /// One line per app for the menu bar. An app's line is about its running cloud build if it
    /// has one, else about its newest build.
    public var menuLines: [ReleaseMenuLine] {
        guard let status else { return [] }
        return status.apps.map { app in
            let builds = status.builds.filter { $0.app == app.id }
            let build = builds.first { storeBuild(for: $0)?.cloudState == .running } ?? builds.first
            let live = build.flatMap { storeBuild(for: $0) }
            var parts = [build?.id ?? "No builds yet"]
            if let text = live?.stateText, !text.isEmpty { parts.append(text) }
            let alerts = store.value?.apps.first { $0.id == app.id }?.alerts?.count ?? 0
            if alerts > 0 { parts.append(alerts == 1 ? "1 alert" : "\(alerts) alerts") }
            return ReleaseMenuLine(
                id: app.id, title: "\(app.name) \(app.version)", detail: parts.joined(separator: " · "), mark: live?.menuMark ?? .none
            )
        }
    }
}

extension RunNotice {
    /// The notice for a change on the store's side.
    public static func make(for change: ReleaseChange, appName: String) -> RunNotice {
        switch change.kind {
        case .cloudSucceeded:
            RunNotice(title: "\(change.build) is built", body: "\(appName): the cloud build succeeded.")
        case .cloudFailed:
            RunNotice(title: "\(change.build) failed in the cloud", body: "\(appName): the cloud build did not succeed.")
        case .reachedTesters(let state):
            RunNotice(title: "\(change.build): \(state)", body: "\(appName): the build reached testing.")
        }
    }
}

/// Keeps the open project's release state fresh while Build Desk is open, and says so when a
/// cloud build ends or a build reaches testers. It only reads: the project's `status` and
/// `store` commands.
@MainActor
@Observable
public final class ReleaseWatchModel {
    public var isEnabled: Bool {
        didSet {
            store.watchesReleases = isEnabled
            restart()
        }
    }
    /// When the store was last read by the watch.
    public private(set) var lastChecked: Date?

    weak var app: AppModel?
    /// Waits between two readings; replaced in tests.
    var sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    private let store: PreferenceStore
    /// False until the app's scenes are up; tests and snapshots never start the loop by accident.
    private var isActive = false
    private var task: Task<Void, Never>?

    public init(store: PreferenceStore) {
        self.store = store
        isEnabled = store.watchesReleases
    }

    /// True when there is something to watch: the open project can tell its live store state.
    public var canWatch: Bool { app?.release?.hasStore == true }

    /// Called once when the app starts.
    public func activate() {
        isActive = true
        restart()
    }

    /// Starts over: on activation, when a project opens or closes, and when the setting changes.
    public func restart() {
        task?.cancel()
        task = nil
        guard isActive, isEnabled, canWatch else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.check()
                let wait = ReleaseWatch.interval(after: self.app?.release?.store.value)
                await self.sleep(wait)
            }
        }
    }

    /// Reads the release state once and announces what changed since the reading before.
    public func check() async {
        guard let app, let release = app.release, release.hasStore else { return }
        let before = release.store.value
        await release.refresh()
        // The project may have been closed or changed while the commands ran.
        guard app.release === release, let after = release.store.value else { return }
        lastChecked = Date()
        guard let before else { return }
        // Someone looking at Release mode has already seen the change.
        guard !(app.environment.isAppActive() && app.mode == .release) else { return }
        for change in ReleaseWatch.changes(from: before, to: after) {
            let name = release.status?.apps.first { $0.id == change.app }?.name ?? change.app
            await app.environment.notifier.post(RunNotice.make(for: change, appName: name))
        }
    }
}

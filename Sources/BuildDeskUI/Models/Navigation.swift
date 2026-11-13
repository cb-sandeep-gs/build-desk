import BuildDeskCore
import Foundation

/// One row of the sidebar: what the window shows.
public enum SidebarItem: Hashable, Sendable {
    case scheme(String)
    /// An app of the project's release workflow, by its id.
    case releaseApp(String)
    case activity
}

extension AppModel {
    /// The sidebar's selection. Choosing a row moves the window to that page and remembers the
    /// scheme or app, so coming back to a section shows what was there before.
    public var sidebarSelection: SidebarItem? {
        get {
            switch mode {
            case .build: project?.selectedSchemeName.map(SidebarItem.scheme)
            case .release: release?.selectedAppID.map(SidebarItem.releaseApp)
            case .activity: .activity
            }
        }
        set {
            switch newValue {
            case .scheme(let name):
                project?.selectedSchemeName = name
                mode = .build
            case .releaseApp(let id):
                guard let release else { return }
                // Another app has other builds: the open one is not among them.
                if release.selectedAppID != id { release.selectedBuildID = nil }
                release.selectedAppID = id
                mode = .release
            case .activity:
                mode = .activity
            case nil:
                break
            }
        }
    }

    /// The apps listed under Release in the sidebar. Before the status is read there are none.
    public var releaseApps: [ReleaseApp] { release?.status?.apps ?? [] }

    /// Build output and tagged files of the open project together, for the sidebar.
    public var storageBytes: Int64? {
        let total = (buildFolder?.buildBytes ?? 0) + (taggedBytes ?? 0)
        return total > 0 ? total : nil
    }
}

/// What the toolbar's status field says: the work in progress, else how the last run ended, else
/// where the release stands.
public struct ToolbarStatus: Equatable, Sendable {
    public enum Tone: Sendable, Equatable {
        case working
        case good
        case bad
        case neutral
    }

    public let text: String
    public let tone: Tone
    /// Zero to one while a measured build is running; nil otherwise.
    public let progress: Double?

    public init(text: String, tone: Tone, progress: Double? = nil) {
        self.text = text
        self.tone = tone
        self.progress = progress
    }
}

extension AppModel {
    public var toolbarStatus: ToolbarStatus {
        if taggedInstall?.phase == .preparing, let install = taggedInstall {
            return ToolbarStatus(text: "Getting \(install.build.version) ready…", tone: .working)
        }
        if tests.isRunning { return ToolbarStatus(text: "Testing \(tests.request?.scheme ?? "")…", tone: .working) }
        if run.isRunning {
            let title = run.job?.title ?? "Building"
            let progress = run.statuses[.build] == .running ? run.buildProgress : nil
            return ToolbarStatus(text: "\(title) · \(run.runningText)", tone: .working, progress: progress)
        }
        switch run.phase {
        case .succeeded: return ToolbarStatus(text: run.successText, tone: .good)
        case .failed(let message): return ToolbarStatus(text: message, tone: .bad)
        case .stopped: return ToolbarStatus(text: "Stopped", tone: .neutral)
        case .idle, .running: break
        }
        // Nothing was run yet: say where the release stands, if the project has one.
        if let line = release?.menuLines.first(where: { $0.id == release?.selectedAppID }) ?? release?.menuLines.first {
            let tone: ToolbarStatus.Tone = switch line.mark {
            case .running: .working
            case .succeeded: .good
            case .failed: .bad
            case .none: .neutral
            }
            return ToolbarStatus(text: "\(line.title) · \(line.detail)", tone: tone)
        }
        return ToolbarStatus(text: "Ready", tone: .neutral)
    }
}

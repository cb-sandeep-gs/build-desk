import BuildDeskCore
import Foundation
import UserNotifications

/// What a run does: the three buttons of the window.
public enum RunMode: Sendable, Equatable {
    case buildAndInstall
    case buildOnly
    /// Installs the app the last build left behind, without rebuilding.
    case installOnly
}

/// A scheme, configuration and device saved together, so the menu bar can run them in one click.
public struct PinnedRun: Codable, Equatable, Identifiable, Sendable {
    public let project: URL
    public let scheme: String
    public let configuration: String
    public let deviceID: String
    /// Kept so the pin can be read while the device is not connected.
    public let deviceName: String

    public var id: String { [project.path, scheme, configuration, deviceID].joined(separator: "|") }

    public init(project: URL, scheme: String, configuration: String, deviceID: String, deviceName: String) {
        self.project = project
        self.scheme = scheme
        self.configuration = configuration
        self.deviceID = deviceID
        self.deviceName = deviceName
    }
}

/// What the user is told when a run ends while Build Desk is in the background.
public struct RunNotice: Equatable, Sendable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }

    /// The notice for a finished run; nil for a run the user stopped, which needs no announcement.
    @MainActor
    public static func make(for run: RunModel) -> RunNotice? {
        guard let job = run.job else { return nil }
        switch run.phase {
        case .succeeded:
            let seconds = (run.finishedAt ?? Date()).timeIntervalSince(run.startedAt ?? Date())
            let result = !job.installs ? "Built" : job.launches ? "Installed and running on \(job.deviceSummary)"
                : "Installed on \(job.deviceSummary)"
            // With several devices, say so when one of them did not get the app.
            let failed = run.deviceOutcomes.filter { !$0.succeeded }.map(\.device.name)
            let note = failed.isEmpty ? "" : " Failed on \(failed.joined(separator: ", "))."
            return RunNotice(title: "\(job.title) is ready", body: "\(result) in \(DurationText.short(seconds)).\(note)")
        case .failed(let message):
            return RunNotice(title: "\(job.title) failed", body: message)
        case .idle, .running, .stopped:
            return nil
        }
    }
}

/// Delivers a notice to the user.
public protocol RunNotifying: Sendable {
    func post(_ notice: RunNotice) async
}

/// Says nothing; the default for tests, the demo and snapshots.
public struct SilentNotifier: RunNotifying {
    public init() {}
    public func post(_ notice: RunNotice) async {}
}

/// Posts a system notification. Permission is asked for the first time there is something to say,
/// not at launch.
public struct UserNotificationNotifier: RunNotifying {
    public init() {}

    public func post(_ notice: RunNotice) async {
        // The notification centre needs a bundled app; a bare executable (`swift run`) has none.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

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
    /// Arguments, environment variables and a link the app is launched with.
    public let launchOptions: LaunchOptions

    /// Launch options are part of what a pin is: the same scheme can be pinned twice, once
    /// plain and once with a debug flag.
    public var id: String {
        [project.path, scheme, configuration, deviceID, launchOptions.argumentsText, launchOptions.environmentText, launchOptions.url ?? ""]
            .joined(separator: "|")
    }

    public init(
        project: URL, scheme: String, configuration: String, deviceID: String, deviceName: String,
        launchOptions: LaunchOptions = LaunchOptions()
    ) {
        self.project = project
        self.scheme = scheme
        self.configuration = configuration
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.launchOptions = launchOptions
    }

    /// Pins saved before launch options existed have none.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        project = try values.decode(URL.self, forKey: .project)
        scheme = try values.decode(String.self, forKey: .scheme)
        configuration = try values.decode(String.self, forKey: .configuration)
        deviceID = try values.decode(String.self, forKey: .deviceID)
        deviceName = try values.decode(String.self, forKey: .deviceName)
        launchOptions = try values.decodeIfPresent(LaunchOptions.self, forKey: .launchOptions) ?? LaunchOptions()
    }
}

/// The launch options of a scheme as the person typed them, kept as text so a half-typed value
/// is not lost.
public struct LaunchTexts: Codable, Equatable, Sendable {
    public var arguments = ""
    public var environment = ""
    public var url = ""

    public init(arguments: String = "", environment: String = "", url: String = "") {
        self.arguments = arguments
        self.environment = environment
        self.url = url
    }

    public init(_ options: LaunchOptions) {
        self.init(arguments: options.argumentsText, environment: options.environmentText, url: options.url ?? "")
    }

    public var isEmpty: Bool { self == LaunchTexts() }

    /// The options the text describes, or what is wrong with it.
    public func options() -> Result<LaunchOptions, LaunchOptions.ParseError> {
        do {
            return .success(try LaunchOptions.parse(arguments: arguments, environment: environment, url: url))
        } catch let error as LaunchOptions.ParseError {
            return .failure(error)
        } catch {
            return .failure(LaunchOptions.ParseError(message: error.localizedDescription))
        }
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

extension RunNotice {
    /// The notice for a finished test run; nil for one the user stopped.
    @MainActor
    public static func make(for tests: TestRunModel) -> RunNotice? {
        guard let scheme = tests.request?.scheme else { return nil }
        switch tests.phase {
        case .finished:
            guard let summary = tests.summary else { return nil }
            let failed = summary.count(.failed)
            let counts = "\(summary.count(.passed)) passed\(failed > 0 ? ", \(failed) failed" : "")"
            return RunNotice(
                title: failed > 0 ? "\(scheme) tests failed" : "\(scheme) tests passed",
                body: "\(counts) in \(DurationText.short(summary.seconds))."
            )
        case .failed(let message):
            return RunNotice(title: "\(scheme) tests could not run", body: message)
        case .idle, .building, .testing, .stopped:
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

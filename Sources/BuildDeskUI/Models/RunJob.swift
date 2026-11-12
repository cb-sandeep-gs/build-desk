import BuildDeskCore
import Foundation

/// What a run is doing: building a scheme, or installing an app file.
public enum RunJob: Sendable, Equatable {
    case build(BuildRequest)
    case install(InstallRequest)

    /// The scheme or app name, as shown in titles and notifications.
    public var title: String {
        switch self {
        case .build(let request): request.scheme
        case .install(let request): request.artifact.name
        }
    }

    public var devices: [Device] {
        switch self {
        case .build(let request): request.allDevices
        case .install(let request): request.devices
        }
    }

    public var builds: Bool {
        if case .build(let request) = self { return request.builds }
        return false
    }

    public var installs: Bool {
        switch self {
        case .build(let request): request.installs
        case .install: true
        }
    }

    public var launches: Bool {
        switch self {
        case .build(let request): request.launches
        case .install(let request): request.launches
        }
    }

    /// "Test iPhone", or "Test iPhone and 2 more" for several devices.
    public var deviceSummary: String {
        guard let first = devices.first else { return "the device" }
        return devices.count == 1 ? first.name : "\(first.name) and \(devices.count - 1) more"
    }

    /// The steps this job goes through, in order.
    var steps: [PipelineStep] {
        PipelineStep.allCases.filter { step in
            switch step {
            case .build: builds
            case .locate: installs && (self.isBuild)
            case .install: installs
            case .launch: installs && launches
            }
        }
    }

    private var isBuild: Bool {
        if case .build = self { return true }
        return false
    }
}

/// What was installed where, kept so the window can say which code is on a device and so the
/// app can be uninstalled or its console opened without building again.
public struct InstallRecord: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let configuration: String
    public let deviceName: String
    public let date: Date
    /// Branch and commit the build came from; nil outside a git checkout.
    public let source: SourceState?

    public init(bundleIdentifier: String, configuration: String, deviceName: String, date: Date, source: SourceState?) {
        self.bundleIdentifier = bundleIdentifier
        self.configuration = configuration
        self.deviceName = deviceName
        self.date = date
        self.source = source
    }

    /// The key a record is kept under: one per project, scheme and device.
    static func key(project: URL, scheme: String, deviceID: String) -> String {
        [project.path, scheme, deviceID].joined(separator: "|")
    }
}

/// Services that do nothing. The default for the parts of the environment a test or the demo
/// does not care about.
public struct InertServices: ArtifactReading, DeviceAppManaging, SourceStateReading, BuildFolderManaging, TestRunning,
    DeviceToolsProviding, ReleaseProviding {
    public init() {}

    public func read(_ url: URL) async throws -> AppArtifact {
        throw BuildDeskError.unreadableArtifact(path: url.path, reason: "reading app files is not available here")
    }

    public func console(bundleIdentifier: String, on device: Device, options: LaunchOptions) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    public func uninstall(bundleIdentifier: String, from device: Device) async throws {}

    public func state(of folder: URL) async -> SourceState? { nil }

    public func buildFolder(for container: ProjectContainer) async -> BuildFolder? { nil }

    public func clean(_ folder: BuildFolder) async throws {}

    public func run(_ request: TestRequest) -> AsyncThrowingStream<TestEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    public func screenshot(of device: Device, to file: URL) async throws {}

    public func copyAppData(bundleIdentifier: String, from device: Device, to folder: URL) async throws {}

    public func crashLogs(forProcess processName: String, on device: Device) async throws -> [CrashLog] { [] }

    public func copy(_ logs: [CrashLog], from device: Device, to folder: URL) async throws {}

    public func status(_ provider: ReleaseProvider) async throws -> ReleaseStatus {
        ReleaseStatus(head: nil, apps: [], builds: [])
    }

    public func plan(_ action: ReleaseAction, _ provider: ReleaseProvider) async throws -> ReleasePlan {
        throw BuildDeskError.releaseCommandMissing(name: "plan")
    }

    public func run(_ action: ReleaseAction, confirming plan: ReleasePlan, _ provider: ReleaseProvider) async throws -> ReleaseResult {
        throw BuildDeskError.releaseCommandMissing(name: "run")
    }
}

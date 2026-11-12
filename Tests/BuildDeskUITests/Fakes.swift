import BuildDeskCore
@testable import BuildDeskUI
import Foundation

/// A value that tests set and fakes read from any thread.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

struct FakeReader: ProjectReading {
    let quick = Locked<Result<ProjectSnapshot, BuildDeskError>?>(nil)
    let full = Locked<Result<ProjectSnapshot, BuildDeskError>?>(nil)

    func quickSnapshot(of container: ProjectContainer) throws -> ProjectSnapshot {
        try (quick.value ?? .success(Sample.snapshot(of: container))).get()
    }

    func fullSnapshot(of container: ProjectContainer) async throws -> ProjectSnapshot {
        try (full.value ?? .success(Sample.snapshot(of: container, extraSchemes: ["PackageScheme"]))).get()
    }
}

struct FakeDiscovery: DeviceDiscovering {
    let result = Locked<Result<[Device], BuildDeskError>>(.success(Sample.devices))
    /// Identifiers of devices that report a locked screen.
    let lockedIDs = Locked<Set<String>>([])

    func devices() async throws -> [Device] { try result.value.get() }

    func isLocked(_ device: Device) async -> Bool? { lockedIDs.value.contains(device.id) }
}

/// Plays a scripted run. With `hangs`, it stays in the build step until the consumer stops it.
struct FakeBuilder: BuildRunning {
    let requests = Locked<[BuildRequest]>([])
    let installRequests = Locked<[InstallRequest]>([])
    let events = Locked<[PipelineEvent]>([])
    let failure = Locked<BuildDeskError?>(nil)
    let hangs = Locked(false)

    func install(_ request: InstallRequest) -> AsyncThrowingStream<PipelineEvent, Error> {
        installRequests.value += [request]
        return play()
    }

    /// Schemes whose builds fail, whatever the script says.
    let failingSchemes = Locked<Set<String>>([])

    func run(_ request: BuildRequest) -> AsyncThrowingStream<PipelineEvent, Error> {
        requests.value += [request]
        guard !failingSchemes.value.contains(request.scheme) else {
            return AsyncThrowingStream { $0.finish(throwing: BuildDeskError.buildFailed(errors: [], logFile: nil)) }
        }
        return play()
    }

    private func play() -> AsyncThrowingStream<PipelineEvent, Error> {
        let (events, failure, hangs) = (events.value, failure.value, hangs.value)
        return AsyncThrowingStream { continuation in
            events.forEach { continuation.yield($0) }
            if hangs { return }
            continuation.finish(throwing: failure)
        }
    }
}

/// A made-up project and devices.
enum Sample {
    static let phone = Device(
        id: "PHONE", name: "Test iPhone", model: "iPhone 17", platform: "iOS", osVersion: "27.2",
        kind: .physical, connection: .wired, isReady: true, isBooted: true
    )
    static let offlinePhone = Device(
        id: "OFFLINE", name: "Old iPhone", model: "iPhone 16", platform: "iOS", osVersion: "26.1",
        kind: .physical, connection: .none, isReady: false, isBooted: false, issue: .notConnected
    )
    static let simulator = Device(
        id: "SIM", name: "iPhone 17 Pro", model: "iPhone 17 Pro", platform: "iOS", osVersion: "27.2",
        kind: .simulator, connection: .local, isReady: true, isBooted: false
    )
    static let watchSimulator = Device(
        id: "WATCH", name: "Apple Watch", model: "Apple Watch", platform: "watchOS", osVersion: "27.2",
        kind: .simulator, connection: .local, isReady: true, isBooted: false
    )
    static let secondPhone = Device(
        id: "PHONE2", name: "Second iPhone", model: "iPhone 16", platform: "iOS", osVersion: "27.0",
        kind: .physical, connection: .network, isReady: true, isBooted: true
    )
    static let devices = [phone, offlinePhone, simulator, watchSimulator]

    static let artifact = AppArtifact(
        url: URL(fileURLWithPath: "/downloads/Sample.ipa"), bundleIdentifier: "com.example.sample",
        name: "Sample", version: "2.1", platform: .iOS, isSimulatorBuild: false
    )

    static let projectURL = URL(fileURLWithPath: "/projects/Sample.xcodeproj")

    static func container() throws -> ProjectContainer { try ProjectContainer(url: projectURL) }

    static func snapshot(
        of container: ProjectContainer, extraSchemes: [String] = [], config: ProjectConfig = ProjectConfig(), configProblem: String? = nil
    ) -> ProjectSnapshot {
        let app = SchemeTarget(name: "Sample", productName: "Sample.app")
        let widget = SchemeTarget(name: "SampleWidget", productName: "SampleWidget.appex")
        let watch = SchemeTarget(name: "SampleWatch", productName: "SampleWatch.app")
        return ProjectSnapshot(
            container: container,
            schemes: [
                Scheme(name: "SampleKit", buildTargets: [SchemeTarget(name: "SampleKit", productName: "SampleKit.framework")]),
                Scheme(name: "Sample", buildTargets: [app],
                       testTargets: [SchemeTarget(name: "SampleTests", productName: "SampleTests.xctest")], runnable: app),
                Scheme(name: "SampleWatch", buildTargets: [watch], runnable: watch),
                Scheme(name: "SampleWidget", buildTargets: [widget, app]),
                Scheme(name: "SampleTests", testTargets: [SchemeTarget(name: "SampleTests", productName: "SampleTests.xctest")]),
            ] + extraSchemes.map { Scheme(name: $0, isShared: false) },
            targets: [
                ProjectTarget(name: "Sample", kind: .application, platform: .iOS),
                ProjectTarget(name: "SampleWidget", kind: .appExtension, platform: .iOS),
                ProjectTarget(name: "SampleWatch", kind: .application, platform: .watchOS),
                ProjectTarget(name: "SampleKit", kind: .framework, platform: .iOS),
            ],
            configurations: ["Release", "Debug", "Staging"],
            defaultConfiguration: "Release",
            config: config,
            configProblem: configProblem
        )
    }

    /// Three tests in two classes: one failed, one skipped.
    static let testSummary = TestRunSummary(
        cases: [
            TestCaseResult(bundle: "SampleTests", suite: "HomeTests", name: "testLoads", status: .passed, seconds: 0.1),
            TestCaseResult(
                bundle: "SampleTests", suite: "CartTests", name: "testTotal", status: .failed, seconds: 0.5,
                failures: [.init(message: "XCTAssertEqual failed", file: "/src/CartTests.swift", line: 64)]
            ),
            TestCaseResult(bundle: "SampleTests", suite: "CartTests", name: "testLater", status: .skipped, seconds: 0),
        ],
        seconds: 12,
        logFile: URL(fileURLWithPath: "/logs/tests.log")
    )

    static let deprecation = Diagnostic(severity: .warning, message: "deprecated", file: "/src/Home.swift", line: 4, column: 1)

    static let summary = RunSummary(
        product: BuiltProduct(appURL: URL(fileURLWithPath: "/derived/Sample.app"), bundleIdentifier: "com.example.sample"),
        taskCount: 3,
        warnings: [deprecation],
        secondsByStep: [.build: 2],
        logFile: URL(fileURLWithPath: "/logs/run.log")
    )

    /// A full successful run as the pipeline reports it.
    static let successfulRun: [PipelineEvent] = [
        .stepStarted(.build),
        .build(.resolvingPackages),
        .build(.task(name: "SwiftCompile", target: "SampleKit")),
        .build(.task(name: "SwiftCompile", target: "Sample")),
        .build(.diagnostic(Diagnostic(severity: .warning, message: "deprecated", file: "/src/Home.swift", line: 4, column: 1))),
        .build(.diagnostic(Diagnostic(severity: .warning, message: "deprecated", file: "/src/Home.swift", line: 4, column: 1))),
        .build(.task(name: "CodeSign", target: "Sample")),
        .build(.outcome(succeeded: true)),
        .stepFinished(.build, seconds: 2),
        .stepStarted(.locate), .stepFinished(.locate, seconds: 0.5),
        .stepStarted(.install), .stepFinished(.install, seconds: 1),
        .stepStarted(.launch), .stepFinished(.launch, seconds: 0.1),
        .deviceFinished(DeviceOutcome(device: phone)),
        .finished(summary),
    ]
}

/// Stands in for the services that work with app files, installed apps and the checkout.
struct FakeDeviceServices: ArtifactReading, DeviceAppManaging, SourceStateReading {
    let artifact = Locked<AppArtifact?>(Sample.artifact)
    let consoleLines = Locked<[String]>([])
    let consoleFailure = Locked<BuildDeskError?>(nil)
    let uninstalled = Locked<[String]>([])
    let uninstallFailure = Locked<BuildDeskError?>(nil)
    let source = Locked<SourceState?>(SourceState(branch: "main", commit: "1a2b3c4", hasLocalChanges: true))

    func read(_ url: URL) async throws -> AppArtifact {
        guard let artifact = artifact.value else {
            throw BuildDeskError.unreadableArtifact(path: url.path, reason: "it has no Info.plist")
        }
        return artifact
    }

    let consoleOptions = Locked<[LaunchOptions]>([])

    func console(bundleIdentifier: String, on device: Device, options: LaunchOptions) -> AsyncThrowingStream<String, Error> {
        consoleOptions.value += [options]
        let (lines, failure) = (consoleLines.value, consoleFailure.value)
        return AsyncThrowingStream { continuation in
            lines.forEach { continuation.yield($0) }
            continuation.finish(throwing: failure)
        }
    }

    func uninstall(bundleIdentifier: String, from device: Device) async throws {
        if let failure = uninstallFailure.value { throw failure }
        uninstalled.value += ["\(bundleIdentifier) from \(device.name)"]
    }

    func state(of folder: URL) async -> SourceState? { source.value }
}

/// Plays a scripted test run. With `hangs`, it stays running until the consumer stops it.
struct FakeTester: TestRunning {
    let requests = Locked<[TestRequest]>([])
    let events = Locked<[TestEvent]>([])
    let failure = Locked<BuildDeskError?>(nil)
    let hangs = Locked(false)

    func run(_ request: TestRequest) -> AsyncThrowingStream<TestEvent, Error> {
        requests.value += [request]
        let (events, failure, hangs) = (events.value, failure.value, hangs.value)
        return AsyncThrowingStream { continuation in
            events.forEach { continuation.yield($0) }
            if hangs { return }
            continuation.finish(throwing: failure)
        }
    }
}

/// Records what was asked of the device tools.
struct FakeDeviceTools: DeviceToolsProviding {
    let calls = Locked<[String]>([])
    let logs = Locked<[CrashLog]>([])
    let failure = Locked<BuildDeskError?>(nil)

    private func record(_ call: String) throws {
        if let failure = failure.value { throw failure }
        calls.value += [call]
    }

    func screenshot(of device: Device, to file: URL) async throws {
        try record("screenshot of \(device.name) to \(file.lastPathComponent)")
    }

    func copyAppData(bundleIdentifier: String, from device: Device, to folder: URL) async throws {
        try record("data of \(bundleIdentifier) from \(device.name) to \(folder.lastPathComponent)")
    }

    func crashLogs(forProcess processName: String, on device: Device) async throws -> [CrashLog] {
        try record("crash logs of \(processName) on \(device.name)")
        return logs.value
    }

    func copy(_ logs: [CrashLog], from device: Device, to folder: URL) async throws {
        try record("copy \(logs.count) logs from \(device.name) to \(folder.lastPathComponent)")
    }
}

/// A build folder on disk that tests can inspect and fail.
struct FakeBuildFolders: BuildFolderManaging {
    let bytes = Locked<Int64?>(4_500_000_000)
    let cleaned = Locked(0)
    let failure = Locked<BuildDeskError?>(nil)

    func buildFolder(for container: ProjectContainer) async -> BuildFolder? {
        BuildFolder(url: URL(fileURLWithPath: "/derived/Sample-abcd"), buildBytes: bytes.value)
    }

    func clean(_ folder: BuildFolder) async throws {
        if let failure = failure.value { throw failure }
        cleaned.value += 1
        bytes.value = nil
    }
}

/// Preferences that live only for one test.
@MainActor
struct TestStore {
    let name = "builddesk.tests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: name) ?? .standard
    }

    func make() -> PreferenceStore { PreferenceStore(defaults: defaults) }

    func remove() { defaults.removePersistentDomain(forName: name) }
}

/// Waits until a condition holds, so a test can follow work that happens in a background task.
@MainActor
func waitUntil(_ condition: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

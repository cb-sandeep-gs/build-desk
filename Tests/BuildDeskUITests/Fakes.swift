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

    func devices() async throws -> [Device] { try result.value.get() }
}

/// Plays a scripted run. With `hangs`, it stays in the build step until the consumer stops it.
struct FakeBuilder: BuildRunning {
    let requests = Locked<[BuildRequest]>([])
    let events = Locked<[PipelineEvent]>([])
    let failure = Locked<BuildDeskError?>(nil)
    let hangs = Locked(false)

    func run(_ request: BuildRequest) -> AsyncThrowingStream<PipelineEvent, Error> {
        requests.value += [request]
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
        kind: .physical, connection: .none, isReady: false, isBooted: false
    )
    static let simulator = Device(
        id: "SIM", name: "iPhone 17 Pro", model: "iPhone 17 Pro", platform: "iOS", osVersion: "27.2",
        kind: .simulator, connection: .local, isReady: true, isBooted: false
    )
    static let watchSimulator = Device(
        id: "WATCH", name: "Apple Watch", model: "Apple Watch", platform: "watchOS", osVersion: "27.2",
        kind: .simulator, connection: .local, isReady: true, isBooted: false
    )
    static let devices = [phone, offlinePhone, simulator, watchSimulator]

    static let projectURL = URL(fileURLWithPath: "/projects/Sample.xcodeproj")

    static func container() throws -> ProjectContainer { try ProjectContainer(url: projectURL) }

    static func snapshot(of container: ProjectContainer, extraSchemes: [String] = []) -> ProjectSnapshot {
        let app = SchemeTarget(name: "Sample", productName: "Sample.app")
        let widget = SchemeTarget(name: "SampleWidget", productName: "SampleWidget.appex")
        let watch = SchemeTarget(name: "SampleWatch", productName: "SampleWatch.app")
        return ProjectSnapshot(
            container: container,
            schemes: [
                Scheme(name: "SampleKit", buildTargets: [SchemeTarget(name: "SampleKit", productName: "SampleKit.framework")]),
                Scheme(name: "Sample", buildTargets: [app], runnable: app),
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
            defaultConfiguration: "Release"
        )
    }

    static let summary = RunSummary(
        product: BuiltProduct(appURL: URL(fileURLWithPath: "/derived/Sample.app"), bundleIdentifier: "com.example.sample"),
        taskCount: 3,
        warnings: [],
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
        .finished(summary),
    ]
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

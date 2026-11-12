import AppKit
import BuildDeskCore
import Foundation

extension AppEnvironment {
    private static let xcodeBundleIdentifier = "com.apple.dt.Xcode"

    /// The real tools.
    public static var live: AppEnvironment {
        AppEnvironment(
            reader: ProjectReader(),
            discovery: DeviceDiscovery(),
            builder: BuildPipeline(),
            isXcodeOpen: {
                NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == xcodeBundleIdentifier }
            },
            notifier: UserNotificationNotifier(),
            isAppActive: { NSApp?.isActive ?? false }
        )
    }
}

/// A made-up project, devices and run, for screenshots and for trying the window without a
/// project. Nothing here touches a real project, device or tool.
public enum Demo {
    private static let defaultsSuite = "builddesk.demo"
    private static let projectURL = URL(fileURLWithPath: "/Projects/Harbor/Harbor.xcodeproj")
    private static let previousTaskCount = 640

    /// Preferences of their own, emptied each time, so a demo or a snapshot never reads or changes
    /// what the user's app remembers.
    @MainActor
    public static func scratchStore() -> PreferenceStore {
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
        return PreferenceStore(defaults: UserDefaults(suiteName: defaultsSuite) ?? .standard)
    }

    /// An app model showing the demo project with a build in progress.
    @MainActor
    public static func runningApp() async -> AppModel {
        let store = scratchStore()
        store.pins = [
            PinnedRun(project: projectURL, scheme: "Harbor", configuration: "Debug", deviceID: "DEMO-PHONE", deviceName: "Harbor iPhone"),
            PinnedRun(project: projectURL, scheme: "Harbor Staging", configuration: "Staging", deviceID: "DEMO-SIM",
                      deviceName: "iPhone 17 Pro"),
            PinnedRun(project: projectURL, scheme: "Harbor", configuration: "Release", deviceID: "DEMO-PAD", deviceName: "Test iPad"),
        ]
        let app = AppModel(environment: environment, store: store)
        await app.open(projectURL)
        await app.refreshEnvironment()
        // As if this scheme had been built before, so the progress bar has something to measure against.
        store.setTaskCount(
            previousTaskCount,
            for: AppModel.taskCountKey(project: projectURL, scheme: "Harbor", configuration: "Debug", deviceKind: .physical)
        )
        app.runSelected(.buildAndInstall)
        // Let the scripted build events arrive.
        try? await Task.sleep(for: .milliseconds(200))
        return app
    }

    static let environment = AppEnvironment(
        reader: DemoReader(), discovery: DemoDiscovery(), builder: DemoBuilder(), isXcodeOpen: { false }
    )

    static let devices: [Device] = [
        Device(id: "DEMO-PHONE", name: "Harbor iPhone", model: "iPhone 17", platform: "iOS", osVersion: "27.2",
               kind: .physical, connection: .wired, isReady: true, isBooted: true),
        Device(id: "DEMO-PAD", name: "Test iPad", model: "iPad Pro", platform: "iOS", osVersion: "27.1",
               kind: .physical, connection: .none, isReady: false, isBooted: false),
        Device(id: "DEMO-SIM", name: "iPhone 17 Pro", model: "iPhone 17 Pro", platform: "iOS", osVersion: "27.2",
               kind: .simulator, connection: .local, isReady: true, isBooted: true),
        Device(id: "DEMO-WATCH", name: "Apple Watch Series 11", model: "Apple Watch", platform: "watchOS", osVersion: "27.2",
               kind: .simulator, connection: .local, isReady: true, isBooted: false),
    ]

    static func snapshot(of container: ProjectContainer) -> ProjectSnapshot {
        func target(_ product: String) -> SchemeTarget {
            SchemeTarget(name: URL(fileURLWithPath: product).deletingPathExtension().lastPathComponent, productName: product)
        }
        let app = target("Harbor.app")
        return ProjectSnapshot(
            container: container,
            schemes: [
                Scheme(name: "Harbor", buildTargets: [app, target("HarborWidget.appex")],
                       testTargets: [target("HarborTests.xctest")], runnable: app),
                Scheme(name: "Harbor Staging", buildTargets: [app], runnable: app),
                Scheme(name: "HarborWatch", buildTargets: [target("HarborWatch.app")], runnable: target("HarborWatch.app")),
                Scheme(name: "HarborWidget", buildTargets: [target("HarborWidget.appex"), app]),
                Scheme(name: "HarborKit", buildTargets: [target("HarborKit.framework")]),
                Scheme(name: "HarborNetworking", buildTargets: [target("HarborNetworking.framework")]),
                Scheme(name: "HarborTests", testTargets: [target("HarborTests.xctest")]),
            ],
            targets: [
                ProjectTarget(name: "Harbor", kind: .application, platform: .iOS),
                ProjectTarget(name: "HarborWidget", kind: .appExtension, platform: .iOS),
                ProjectTarget(name: "HarborWatch", kind: .application, platform: .watchOS),
                ProjectTarget(name: "HarborKit", kind: .framework, platform: .iOS),
                ProjectTarget(name: "HarborNetworking", kind: .framework, platform: .iOS),
                ProjectTarget(name: "HarborTests", kind: .unitTests, platform: .iOS),
            ],
            configurations: ["Debug", "Staging", "Release"],
            defaultConfiguration: "Release"
        )
    }
}

private struct DemoReader: ProjectReading {
    func quickSnapshot(of container: ProjectContainer) throws -> ProjectSnapshot { Demo.snapshot(of: container) }
    func fullSnapshot(of container: ProjectContainer) async throws -> ProjectSnapshot { Demo.snapshot(of: container) }
}

private struct DemoDiscovery: DeviceDiscovering {
    func devices() async throws -> [Device] { Demo.devices }
}

/// Plays the start of a build and then stays "building" until stopped.
private struct DemoBuilder: BuildRunning {
    private static let taskCount = 412

    func run(_ request: BuildRequest) -> AsyncThrowingStream<PipelineEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.stepStarted(.build))
            for index in 0..<Self.taskCount {
                continuation.yield(.build(.task(name: "SwiftCompile", target: index < Self.taskCount / 2 ? "HarborKit" : "Harbor")))
            }
            continuation.yield(.build(.diagnostic(Diagnostic(
                severity: .warning, message: "'loadCatalog()' is deprecated: use loadCatalog(for:)",
                file: "/Projects/Harbor/Sources/CatalogView.swift", line: 41, column: 13
            ))))
            continuation.yield(.build(.diagnostic(Diagnostic(
                severity: .warning, message: "variable 'retries' was never mutated; consider changing to 'let'",
                file: "/Projects/Harbor/Sources/SyncEngine.swift", line: 118, column: 9
            ))))
        }
    }
}

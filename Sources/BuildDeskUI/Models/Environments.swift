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
            isAppActive: { NSApp?.isActive ?? false },
            artifacts: ArtifactReader(),
            deviceApps: DeviceAppService(),
            source: SourceStateReader(),
            // Without a support folder, history still works for the session.
            history: FileRunHistoryStore.defaultDirectory.map { FileRunHistoryStore(directory: $0) } ?? MemoryRunHistoryStore(),
            buildFolders: BuildFolderService(),
            tester: TestRunner(),
            deviceTools: DeviceToolsService(),
            releases: ReleaseClient(),
            taggedSources: TaggedCheckout()
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

    /// What the demo shows.
    public enum Scene: Sendable {
        /// A build in progress.
        case building
        /// After an install: the last-install line and the app's console.
        case installed
        /// An app file waiting for a device to be chosen.
        case appFile
        /// After a test run with failures.
        case tested
        /// Release mode.
        case release
        /// A release action with its plan on screen, waiting for the confirmation.
        case releaseAction
        /// A release build being built from its tag and installed.
        case taggedInstall
    }

    /// An app model showing the demo project in the given scene.
    @MainActor
    public static func app(showing scene: Scene = .building) async -> AppModel {
        let store = scratchStore()
        store.pins = [
            PinnedRun(project: projectURL, scheme: "Harbor", configuration: "Debug", deviceID: "DEMO-PHONE", deviceName: "Harbor iPhone"),
            PinnedRun(project: projectURL, scheme: "Harbor Staging", configuration: "Staging", deviceID: "DEMO-SIM",
                      deviceName: "iPhone 17 Pro",
                      launchOptions: LaunchOptions(arguments: ["-skipOnboarding"], environment: ["API_HOST": "staging.example.com"])),
            PinnedRun(project: projectURL, scheme: "Harbor", configuration: "Release", deviceID: "DEMO-PAD", deviceName: "Test iPad"),
        ]
        // As if this scheme had been built before, so the progress bar has something to measure against.
        store.setTaskCount(
            previousTaskCount,
            for: AppModel.taskCountKey(project: projectURL, scheme: "Harbor", configuration: "Debug", deviceKind: .physical)
        )
        store.launchTexts = [
            AppModel.launchTextsKey(project: projectURL, scheme: "Harbor"): LaunchTexts(
                arguments: "-skipOnboarding -logLevel debug", environment: "API_HOST=staging.example.com", url: "harbor://cart"
            ),
        ]
        if scene == .installed {
            store.installRecords = [
                InstallRecord.key(project: projectURL, scheme: "Harbor", deviceID: "DEMO-PHONE"): InstallRecord(
                    bundleIdentifier: "com.example.harbor", configuration: "Debug", deviceName: "Harbor iPhone",
                    date: Date().addingTimeInterval(-lastInstallAge),
                    source: SourceState(branch: "feature/checkout", commit: "1a2b3c4", hasLocalChanges: true)
                ),
            ]
        }
        let app = AppModel(environment: environment, store: store)
        await app.open(projectURL)
        await app.refreshEnvironment()
        switch scene {
        case .building: app.runSelected(.buildAndInstall)
        case .installed: app.openConsoleForSelection()
        case .appFile: await app.openDropped(URL(fileURLWithPath: "/Downloads/Harbor.ipa"))
        case .tested: app.runTests()
        case .release:
            app.mode = .release
            await app.release?.refresh()
            app.release?.selectedBuildID = "HarborInternal-4.2.2"
        case .releaseAction:
            app.mode = .release
            await app.release?.refresh()
            app.release?.begin(.testflight)
            await app.release?.activeAction?.preview()
        case .taggedInstall: await startTaggedInstall(in: app)
        }
        // Let the scripted events arrive.
        try? await Task.sleep(for: .milliseconds(200))
        return app
    }

    /// Release mode with an older build being built from its tag.
    @MainActor
    private static func startTaggedInstall(in app: AppModel) async {
        let id = "HarborInternal-4.2.2"
        app.mode = .release
        await app.release?.refresh()
        app.release?.selectedBuildID = id
        await app.refreshTaggedSource()
        guard let build = app.release?.builds.first(where: { $0.id == id }) else { return }
        // Not awaited: the picture is taken while the build is running.
        Task { await app.installTagged(build) }
    }

    private static let lastInstallAge: TimeInterval = 2 * 60 * 60

    static let environment = AppEnvironment(
        reader: DemoReader(), discovery: DemoDiscovery(), builder: DemoBuilder(), isXcodeOpen: { false },
        artifacts: DemoDeviceServices(), deviceApps: DemoDeviceServices(),
        history: MemoryRunHistoryStore(records: history), buildFolders: DemoDeviceServices(), tester: DemoTester(),
        releases: DemoRelease(), taggedSources: DemoTaggedSources()
    )

    /// Two weeks of made-up runs, with one slow build and one failure.
    static let history: [RunRecord] = {
        let buildSeconds: [Double] = [212, 38, 41, 35, 198, 44, 39, 52, 47, 301, 43, 40]
        let day: TimeInterval = 24 * 60 * 60
        return buildSeconds.enumerated().map { index, seconds in
            let age = Double(buildSeconds.count - index) * day + lastInstallAge
            let failed = index == buildSeconds.count - 3
            return RunRecord(
                date: Date().addingTimeInterval(-age), projectPath: projectURL.path, scheme: "Harbor", configuration: "Debug",
                deviceName: "Harbor iPhone", deviceKind: .physical, action: .buildAndInstall, result: failed ? .failed : .succeeded,
                totalSeconds: seconds + 14, buildSeconds: failed ? nil : seconds, taskCount: 640, warningCount: 18,
                newWarningCount: index == buildSeconds.count - 1 ? 2 : 0, errorCount: failed ? 1 : 0,
                source: SourceState(branch: "feature/checkout", commit: "1a2b3c4", hasLocalChanges: index % 3 == 0)
            )
        }
    }()

    static let devices: [Device] = [
        Device(id: "DEMO-PHONE", name: "Harbor iPhone", model: "iPhone 17", platform: "iOS", osVersion: "27.2",
               kind: .physical, connection: .wired, isReady: true, isBooted: true),
        Device(id: "DEMO-PHONE-2", name: "QA iPhone", model: "iPhone 16", platform: "iOS", osVersion: "27.0",
               kind: .physical, connection: .network, isReady: true, isBooted: true),
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
            defaultConfiguration: "Release",
            config: ProjectConfig(
                favoriteSchemes: ["Harbor", "Harbor Staging"], hiddenSchemes: ["*Tests"],
                release: ReleaseCommands(
                    status: ["./tool", "status"], plan: ["./tool", "plan"], run: ["./tool", "run"], checks: ["./tool", "checks"],
                    store: ["./tool", "store"], artifact: ["./tool", "artifact"]
                )
            ),
            configFolder: URL(fileURLWithPath: "/Projects/Harbor")
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

    func install(_ request: InstallRequest) -> AsyncThrowingStream<PipelineEvent, Error> {
        AsyncThrowingStream { $0.yield(.stepStarted(.install)) }
    }

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

/// A made-up app file and console output.
private struct DemoDeviceServices: ArtifactReading, DeviceAppManaging, BuildFolderManaging {
    private static let buildBytes: Int64 = 4_630_000_000

    func buildFolder(for container: ProjectContainer) async -> BuildFolder? {
        BuildFolder(url: URL(fileURLWithPath: "/Users/you/Library/Developer/Xcode/DerivedData/Harbor-demo"), buildBytes: Self.buildBytes)
    }

    func clean(_ folder: BuildFolder) async throws {}
    func totalBytes(of folder: BuildFolder) async -> Int64? { Self.buildBytes }
    func removeAll(_ folder: BuildFolder) async throws {}

    func read(_ url: URL) async throws -> AppArtifact {
        AppArtifact(
            url: url, bundleIdentifier: "com.example.harbor", name: "Harbor", version: "4.2", platform: .iOS, isSimulatorBuild: false
        )
    }

    /// Prints a few lines and then stays attached, like an app that is running.
    func console(bundleIdentifier: String, on device: Device, options: LaunchOptions) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            [
                "Harbor 4.2 (812) launched",
                "session: restored for user 1042",
                "network: GET /v2/catalog → 200 in 184 ms",
                "catalog: 126 items, 4 collections",
                "network: GET /v2/cart → 200 in 96 ms",
                "push: registered for remote notifications",
            ].forEach { continuation.yield($0) }
        }
    }

    func uninstall(bundleIdentifier: String, from device: Device) async throws {}
}

/// A finished test run with two failures.
private struct DemoTester: TestRunning {
    func run(_ request: TestRequest) -> AsyncThrowingStream<TestEvent, Error> {
        let suites: [(String, [String])] = [
            ("CartTests", ["testAddItem", "testRemoveItem", "testTotalWithDiscount", "testEmptyCart"]),
            ("CatalogTests", ["testLoadsFirstPage", "testSearchFilters", "testSortByPrice"]),
            ("CheckoutTests", ["testPaysWithSavedCard", "testAddressValidation", "testRetryAfterTimeout"]),
            ("SessionTests", ["testRestoresSession", "testSignsOut"]),
        ]
        let failing: [String: TestCaseResult.Failure] = [
            "testTotalWithDiscount": .init(
                message: "XCTAssertEqual failed: (\"18.00\") is not equal to (\"17.10\")",
                file: "/Projects/Harbor/Tests/CartTests.swift", line: 64
            ),
            "testRetryAfterTimeout": .init(
                message: "Asynchronous wait failed: Exceeded timeout of 5 seconds, with unfulfilled expectations: \"retry\"",
                file: "/Projects/Harbor/Tests/CheckoutTests.swift", line: 131
            ),
        ]
        let cases = suites.flatMap { suite, names in
            names.map { name in
                TestCaseResult(
                    bundle: "HarborTests", suite: suite, name: name,
                    status: failing[name] != nil ? .failed : name == "testSignsOut" ? .skipped : .passed,
                    seconds: 0.2, failures: failing[name].map { [$0] } ?? []
                )
            }
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.testingStarted)
            continuation.yield(.finished(TestRunSummary(cases: cases, seconds: 64, logFile: nil)))
            continuation.finish()
        }
    }
}

/// A made-up release status: two apps, two tracks each.

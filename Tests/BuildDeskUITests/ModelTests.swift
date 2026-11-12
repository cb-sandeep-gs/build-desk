import BuildDeskCore
@testable import BuildDeskUI
import XCTest

@MainActor
final class ProjectModelTests: XCTestCase {
    func testLoadStartsOnTheFirstInstallableSchemeInDebug() async throws {
        let store = TestStore()
        defer { store.remove() }
        let model = ProjectModel(container: try Sample.container(), reader: FakeReader(), store: store.make())
        XCTAssertEqual(model.state, .idle)

        await model.load()

        // "SampleKit" comes first in the project but cannot be installed.
        XCTAssertEqual(model.selectedSchemeName, "Sample")
        // Still an app when an installable extension scheme sorts ahead of it.
        let reader = FakeReader()
        let container = try Sample.container()
        let widget = SchemeTarget(name: "AWidget", productName: "AWidget.appex")
        let app = SchemeTarget(name: "Sample", productName: "Sample.app")
        reader.quick.value = .success(ProjectSnapshot(
            container: container,
            schemes: [Scheme(name: "AWidget", buildTargets: [widget, app]), Scheme(name: "Sample", buildTargets: [app], runnable: app)],
            targets: [], configurations: ["Debug"], defaultConfiguration: nil
        ))
        let other = ProjectModel(container: container, reader: reader, store: TestStore().make())
        await other.load()
        XCTAssertEqual(other.selectedSchemeName, "Sample")
        // Debug, not the project's Release default: this is a development install.
        XCTAssertEqual(model.selectedConfiguration, "Debug")
        XCTAssertEqual(model.groups.map(\.title), ["Apps", "Extensions", "Frameworks", "Tests"])
        XCTAssertEqual(model.groups.first?.schemes.map(\.name), ["Sample", "SampleWatch"])
    }

    func testSelectionIsRememberedPerProject() async throws {
        let store = TestStore()
        defer { store.remove() }
        let first = ProjectModel(container: try Sample.container(), reader: FakeReader(), store: store.make())
        await first.load()
        first.selectedSchemeName = "SampleKit"
        first.selectedConfiguration = "Staging"

        let reopened = ProjectModel(container: try Sample.container(), reader: FakeReader(), store: store.make())
        await reopened.load()

        XCTAssertEqual(reopened.selectedSchemeName, "SampleKit")
        XCTAssertEqual(reopened.selectedConfiguration, "Staging")
        XCTAssertEqual(reopened.selectedScheme?.kind, .framework)
    }

    func testFilterNarrowsTheListWithoutCase() async throws {
        let store = TestStore()
        defer { store.remove() }
        let model = ProjectModel(container: try Sample.container(), reader: FakeReader(), store: store.make())
        await model.load()

        model.filter = " WIDGET "
        XCTAssertEqual(model.groups.flatMap(\.schemes).map(\.name), ["SampleWidget"])
        model.filter = "nothing like this"
        XCTAssertTrue(model.groups.isEmpty)
    }

    func testFailedLoadShowsTheReason() async throws {
        let store = TestStore()
        defer { store.remove() }
        let reader = FakeReader()
        reader.quick.value = .failure(.unreadableProject(path: "/projects/Sample.xcodeproj", reason: "damaged"))
        let model = ProjectModel(container: try Sample.container(), reader: reader, store: store.make())

        await model.load()

        XCTAssertEqual(model.state, .failed("Couldn't read /projects/Sample.xcodeproj: damaged"))
        XCTAssertNil(model.selectedScheme)
    }

    func testAllSchemesAreAddedOnRequestAndKeepTheSelection() async throws {
        let store = TestStore()
        defer { store.remove() }
        let model = ProjectModel(container: try Sample.container(), reader: FakeReader(), store: store.make())
        await model.load()
        model.selectedSchemeName = "SampleWidget"

        await model.loadAllSchemes()

        XCTAssertTrue(model.hasAllSchemes)
        XCTAssertEqual(model.groups.last?.schemes.map(\.name), ["PackageScheme"])
        XCTAssertEqual(model.selectedSchemeName, "SampleWidget")
    }

    func testFailedFullListingKeepsTheQuickList() async throws {
        let store = TestStore()
        defer { store.remove() }
        let reader = FakeReader()
        reader.full.value = .failure(.toolFailed(tool: "xcodebuild", exitCode: 74, message: "busy"))
        let model = ProjectModel(container: try Sample.container(), reader: reader, store: store.make())
        await model.load()

        await model.loadAllSchemes()

        XCTAssertFalse(model.hasAllSchemes)
        XCTAssertEqual(model.allSchemesError, "xcodebuild failed (exit 74). busy")
        XCTAssertEqual(model.snapshot?.schemes.count, 5)
    }
}

@MainActor
final class DeviceListModelTests: XCTestCase {
    func testRefreshLoadsDevicesAndRemembersTheChoice() async {
        let store = TestStore()
        defer { store.remove() }
        let model = DeviceListModel(discovery: FakeDiscovery(), store: store.make())

        await model.refresh()
        model.selectedDeviceID = Sample.simulator.id

        XCTAssertEqual(model.devices, Sample.devices)
        XCTAssertEqual(model.selectedDevice, Sample.simulator)
        XCTAssertEqual(DeviceListModel(discovery: FakeDiscovery(), store: store.make()).selectedDeviceID, Sample.simulator.id)
    }

    func testFirstFailureIsShownButALaterOneKeepsTheList() async {
        let store = TestStore()
        defer { store.remove() }
        let discovery = FakeDiscovery()
        discovery.result.value = .failure(.toolFailed(tool: "xcrun devicectl", exitCode: 1, message: "no CoreDevice"))
        let model = DeviceListModel(discovery: discovery, store: store.make())

        await model.refresh()
        XCTAssertEqual(model.state, .failed("xcrun devicectl failed (exit 1). no CoreDevice"))

        discovery.result.value = .success([Sample.phone])
        await model.refresh()
        discovery.result.value = .failure(.toolFailed(tool: "xcrun devicectl", exitCode: 1, message: "again"))
        await model.refresh()
        XCTAssertEqual(model.devices, [Sample.phone])
    }
}

@MainActor
final class RunModelTests: XCTestCase {
    private func request(installs: Bool = true, launches: Bool = true) throws -> BuildRequest {
        BuildRequest(container: try Sample.container(), scheme: "Sample", device: Sample.phone, installs: installs, launches: launches)
    }

    func testSuccessfulRunEndsWithEveryStepDone() async throws {
        let builder = FakeBuilder()
        builder.events.value = Sample.successfulRun
        let model = RunModel(builder: builder)

        model.start(try request(), expectedTaskCount: 6)
        XCTAssertTrue(model.isRunning)
        await model.waitUntilFinished()

        XCTAssertEqual(model.phase, .succeeded)
        XCTAssertEqual(model.steps, [.build, .locate, .install, .launch])
        XCTAssertEqual(model.statuses[.build], .done(seconds: 2))
        XCTAssertEqual(model.statuses[.launch], .done(seconds: 0.1))
        XCTAssertEqual(model.taskCount, 3)
        XCTAssertEqual(model.buildProgress, 0.5)
        // The same warning printed twice is shown once.
        XCTAssertEqual(model.warnings.count, 1)
        XCTAssertEqual(model.logFile?.path, "/logs/run.log")
        XCTAssertNil(model.currentTarget)
        XCTAssertNotNil(model.finishedAt)
    }

    func testProgressIsUnknownWithoutAPreviousBuildAndNeverReachesTheEndEarly() async throws {
        let builder = FakeBuilder()
        builder.events.value = Sample.successfulRun
        let model = RunModel(builder: builder)

        model.start(try request())
        await model.waitUntilFinished()
        XCTAssertNil(model.buildProgress)

        // This build ran more tasks than the last one: the bar holds just short of full.
        model.start(try request(), expectedTaskCount: 2)
        await model.waitUntilFinished()
        XCTAssertEqual(model.buildProgress, 0.98)
    }

    func testBuildOnlyAndNoLaunchRunsHaveFewerSteps() throws {
        let model = RunModel(builder: FakeBuilder())
        model.start(try request(installs: false))
        XCTAssertEqual(model.steps, [.build])

        let noLaunch = RunModel(builder: FakeBuilder())
        noLaunch.start(try request(launches: false))
        XCTAssertEqual(noLaunch.steps, [.build, .locate, .install])
    }

    func testFailedBuildShowsErrorsAndMarksTheStep() async throws {
        let builder = FakeBuilder()
        let error = Diagnostic(severity: .error, message: "cannot find 'missing' in scope", file: "/src/Home.swift", line: 12, column: 5)
        builder.events.value = [.stepStarted(.build), .build(.diagnostic(error))]
        builder.failure.value = .buildFailed(errors: [error], logFile: "/logs/failed.log")
        let model = RunModel(builder: builder)

        model.start(try request())
        await model.waitUntilFinished()

        XCTAssertEqual(model.phase, .failed("The build failed with 1 error. First: cannot find 'missing' in scope"))
        XCTAssertEqual(model.statuses[.build], .failed)
        XCTAssertEqual(model.statuses[.install], .pending)
        XCTAssertEqual(model.errors, [error])
        XCTAssertEqual(model.logFile?.path, "/logs/failed.log")
    }

    func testStopEndsARunningBuild() async throws {
        let builder = FakeBuilder()
        builder.events.value = [.stepStarted(.build), .build(.task(name: "SwiftCompile", target: "Sample"))]
        builder.hangs.value = true
        let model = RunModel(builder: builder)

        model.start(try request())
        await waitUntil { model.taskCount == 1 }
        // A second start while one is running is ignored.
        model.start(try request(installs: false))
        XCTAssertEqual(builder.requests.value.count, 1)

        model.stop()
        await model.waitUntilFinished()

        XCTAssertEqual(model.phase, .stopped)
        XCTAssertEqual(model.statuses[.build], .failed)
        XCTAssertFalse(model.isRunning)
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    private func environment(
        reader: FakeReader = FakeReader(), discovery: FakeDiscovery = FakeDiscovery(), builder: FakeBuilder = FakeBuilder()
    ) -> AppEnvironment {
        AppEnvironment(reader: reader, discovery: discovery, builder: builder, isXcodeOpen: { true })
    }

    private func openApp(_ store: TestStore, builder: FakeBuilder = FakeBuilder()) async -> AppModel {
        let app = AppModel(environment: environment(builder: builder), store: store.make())
        await app.open(Sample.projectURL)
        await app.refreshEnvironment()
        return app
    }

    func testOpeningAFolderFindsTheProjectInside() async throws {
        let store = TestStore()
        defer { store.remove() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("builddesk-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let projectFolder = folder.appendingPathComponent("Source/App.xcodeproj")
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
        let app = AppModel(environment: environment(), store: store.make())

        await app.open(folder)

        XCTAssertEqual(app.project?.container.name, "App")
        XCTAssertEqual(app.recentProjects.map(\.lastPathComponent), ["App.xcodeproj"])
        XCTAssertNil(app.openError)
    }

    func testOpeningSomethingElseExplainsWhy() async {
        let store = TestStore()
        defer { store.remove() }
        let app = AppModel(environment: environment(), store: store.make())

        await app.open(URL(fileURLWithPath: "/nowhere/notes.txt"))

        XCTAssertNil(app.project)
        XCTAssertEqual(app.openError, "/nowhere/notes.txt is not an Xcode project. Choose a .xcodeproj or .xcworkspace.")
    }

    func testAMissingRecentProjectIsForgottenNotReopened() async {
        let store = TestStore()
        defer { store.remove() }
        store.make().noteOpened(URL(fileURLWithPath: "/gone/Old.xcodeproj"))
        let app = AppModel(environment: environment(), store: store.make())

        await app.restoreLastProject()

        XCTAssertNil(app.project)
        XCTAssertTrue(app.recentProjects.isEmpty)
    }

    func testDevicesAreOfferedByPlatform() async {
        let store = TestStore()
        defer { store.remove() }
        let app = await openApp(store)

        XCTAssertTrue(app.isXcodeOpen)
        XCTAssertEqual(app.devicesForSelectedScheme, [Sample.phone, Sample.offlinePhone, Sample.simulator])
        // Nothing chosen yet: the first ready device is used.
        XCTAssertEqual(app.selectedDevice, Sample.phone)

        app.project?.selectedSchemeName = "SampleWatch"
        XCTAssertEqual(app.devicesForSelectedScheme, [Sample.watchSimulator])
        XCTAssertEqual(app.selectedDevice, Sample.watchSimulator)
    }

    func testRunIsBlockedWithAReason() async {
        let store = TestStore()
        defer { store.remove() }
        let app = AppModel(environment: environment(), store: store.make())
        XCTAssertEqual(app.runBlocker, "Choose a scheme.")

        await app.open(Sample.projectURL)
        XCTAssertEqual(app.runBlocker, "Connect a device or choose a simulator.")

        await app.refreshEnvironment()
        XCTAssertNil(app.runBlocker)

        app.devices.selectedDeviceID = Sample.offlinePhone.id
        XCTAssertEqual(app.runBlocker, "Old iPhone is not connected. Connect and unlock it.")
    }

    func testRunUsesTheSelectionAndRemembersTheBuildSize() async {
        let store = TestStore()
        defer { store.remove() }
        let builder = FakeBuilder()
        builder.events.value = Sample.successfulRun
        let app = await openApp(store, builder: builder)
        app.project?.selectedConfiguration = "Staging"
        app.launchesAfterInstall = false

        app.runSelected(.buildAndInstall)
        await app.run.waitUntilFinished()

        let request = builder.requests.value.first
        XCTAssertEqual(request?.scheme, "Sample")
        XCTAssertEqual(request?.configuration, "Staging")
        XCTAssertEqual(request?.device, Sample.phone)
        XCTAssertEqual(request?.installs, true)
        XCTAssertEqual(request?.launches, false)
        XCTAssertNil(app.run.expectedTaskCount)

        // The next run of the same scheme measures its progress against this one.
        await waitUntil { store.make().taskCount(for: "/projects/Sample.xcodeproj|Sample|Staging|physical") == 3 }
        app.runSelected(.buildAndInstall)
        await app.run.waitUntilFinished()
        XCTAssertEqual(app.run.expectedTaskCount, 3)
    }

    func testSchemesWithoutAnAppAreBuiltNotInstalled() async {
        let store = TestStore()
        defer { store.remove() }
        let builder = FakeBuilder()
        let app = await openApp(store, builder: builder)

        app.project?.selectedSchemeName = "SampleKit"
        app.runSelected(.buildAndInstall)
        await app.run.waitUntilFinished()
        // An extension scheme that also builds its app can be installed, like in Xcode.
        app.project?.selectedSchemeName = "SampleWidget"
        app.runSelected(.buildAndInstall)
        await app.run.waitUntilFinished()

        XCTAssertEqual(builder.requests.value.map(\.installs), [false, true])
    }
}

final class DurationTextTests: XCTestCase {
    func testShortDurations() {
        XCTAssertEqual(DurationText.short(0.4), "0 s")
        XCTAssertEqual(DurationText.short(59.4), "59 s")
        XCTAssertEqual(DurationText.short(60), "1 m 0 s")
        XCTAssertEqual(DurationText.short(224.5), "3 m 45 s")
    }
}

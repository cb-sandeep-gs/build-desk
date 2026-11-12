import BuildDeskCore
@testable import BuildDeskUI
import XCTest

@MainActor
final class ExtrasModelTests: XCTestCase {
    private func makeApp(
        _ store: TestStore,
        builder: FakeBuilder = FakeBuilder(),
        services: FakeDeviceServices = FakeDeviceServices(),
        devices: [Device] = Sample.devices + [Sample.secondPhone],
        opensProject: Bool = true
    ) async -> AppModel {
        let discovery = FakeDiscovery()
        discovery.result.value = .success(devices)
        let environment = AppEnvironment(
            reader: FakeReader(), discovery: discovery, builder: builder, isXcodeOpen: { false },
            artifacts: services, deviceApps: services, source: services
        )
        let app = AppModel(environment: environment, store: store.make())
        if opensProject {
            await app.open(Sample.projectURL)
            await app.refreshEnvironment()
        }
        return app
    }

    func testExtraDevicesAreTheSameKindAndGoIntoTheRequest() async {
        let store = TestStore()
        defer { store.remove() }
        let builder = FakeBuilder()
        let app = await makeApp(store, builder: builder)

        // The offline phone and the simulators are not offered beside a connected phone.
        XCTAssertEqual(app.extraDeviceCandidates, [Sample.secondPhone])
        app.extraDeviceIDs = [Sample.secondPhone.id, Sample.simulator.id]
        XCTAssertEqual(app.extraDevices, [Sample.secondPhone])

        app.runSelected(.buildAndInstall)
        await app.run.waitUntilFinished()
        app.runSelected(.buildOnly)
        await app.run.waitUntilFinished()

        XCTAssertEqual(builder.requests.value.map(\.additionalDevices), [[Sample.secondPhone], []])
    }

    func testASuccessfulInstallIsRecordedWithTheCodeItCameFrom() async {
        let store = TestStore()
        defer { store.remove() }
        let builder = FakeBuilder()
        builder.events.value = Sample.successfulRun
        let app = await makeApp(store, builder: builder)
        XCTAssertNil(app.lastInstall)

        app.runSelected(.buildAndInstall)
        await waitUntil { app.lastInstall != nil }

        XCTAssertEqual(app.lastInstall?.bundleIdentifier, "com.example.sample")
        XCTAssertEqual(app.lastInstall?.deviceName, "Test iPhone")
        XCTAssertEqual(app.lastInstall?.source, SourceState(branch: "main", commit: "1a2b3c4", hasLocalChanges: true))
        // Kept for the next launch, and per device: the simulator has nothing installed.
        XCTAssertEqual(store.make().installRecords.count, 1)
        app.devices.selectedDeviceID = Sample.simulator.id
        XCTAssertNil(app.lastInstall)
    }

    func testUninstallRemovesTheAppAndItsRecord() async {
        let store = TestStore()
        defer { store.remove() }
        let builder = FakeBuilder()
        builder.events.value = Sample.successfulRun
        let services = FakeDeviceServices()
        let app = await makeApp(store, builder: builder, services: services)
        app.runSelected(.buildAndInstall)
        await waitUntil { app.lastInstall != nil }

        services.uninstallFailure.value = .toolFailed(tool: "xcrun devicectl", exitCode: 1, message: "The device is locked.")
        await app.uninstallSelection()
        XCTAssertEqual(app.uninstallMessage, "xcrun devicectl failed (exit 1). The device is locked.")
        XCTAssertNotNil(app.lastInstall)

        services.uninstallFailure.value = nil
        await app.uninstallSelection()
        XCTAssertEqual(services.uninstalled.value, ["com.example.sample from Test iPhone"])
        XCTAssertEqual(app.uninstallMessage, "Removed Sample from Test iPhone.")
        XCTAssertNil(app.lastInstall)
    }

    func testADroppedAppFileIsInstalledOnTheChosenDevices() async {
        let store = TestStore()
        defer { store.remove() }
        let builder = FakeBuilder()
        builder.events.value = [.stepStarted(.install), .stepFinished(.install, seconds: 1), .finished(Sample.summary)]
        // No project is open: an app file needs none.
        let app = await makeApp(store, builder: builder, opensProject: false)

        await app.openDropped(URL(fileURLWithPath: "/downloads/Sample.ipa"))

        XCTAssertEqual(app.pendingArtifact, Sample.artifact)
        XCTAssertNil(app.project)
        // A device build: only connected real devices.
        XCTAssertEqual(app.devicesForPendingArtifact, [Sample.phone, Sample.secondPhone])

        app.launchesAfterInstall = false
        app.installPendingArtifact(on: [Sample.secondPhone.id, Sample.simulator.id])
        await app.run.waitUntilFinished()

        XCTAssertEqual(builder.installRequests.value, [
            InstallRequest(artifact: Sample.artifact, devices: [Sample.secondPhone], launches: false),
        ])
        XCTAssertEqual(app.run.steps, [.install])
        XCTAssertEqual(app.run.phase, .succeeded)
        XCTAssertEqual(app.run.job?.title, "Sample")
        app.dismissPendingArtifact()
        XCTAssertNil(app.pendingArtifact)
    }

    func testAnUnreadableAppFileSaysWhyAndAProjectStillOpens() async {
        let store = TestStore()
        defer { store.remove() }
        let services = FakeDeviceServices()
        services.artifact.value = nil
        let app = await makeApp(store, services: services, opensProject: false)

        await app.openDropped(URL(fileURLWithPath: "/downloads/Broken.app"))
        XCTAssertNil(app.pendingArtifact)
        XCTAssertEqual(
            app.openError,
            "Couldn't read /downloads/Broken.app as an app: it has no Info.plist. Choose a .app or .ipa built for a device or simulator."
        )
        app.clearOpenError()

        await app.openDropped(Sample.projectURL)
        XCTAssertEqual(app.project?.container.name, "Sample")
    }

    func testNoticeNamesTheDevicesThatFailed() async {
        let builder = FakeBuilder()
        builder.events.value = [
            .deviceFinished(DeviceOutcome(device: Sample.phone)),
            .deviceFinished(DeviceOutcome(device: Sample.secondPhone, failure: "locked")),
            .finished(Sample.summary),
        ]
        let run = RunModel(builder: builder)
        run.start(InstallRequest(artifact: Sample.artifact, devices: [Sample.phone, Sample.secondPhone]))
        await run.waitUntilFinished()

        let notice = RunNotice.make(for: run)
        XCTAssertEqual(notice?.title, "Sample is ready")
        XCTAssertTrue(notice?.body.hasPrefix("Installed and running on Test iPhone and 1 more in ") == true)
        XCTAssertTrue(notice?.body.hasSuffix(" Failed on Second iPhone.") == true)
        XCTAssertEqual(run.successText, "Sample is installed and running on Test iPhone.")
    }
}

@MainActor
final class ConsoleModelTests: XCTestCase {
    func testConsoleCollectsFiltersAndClearsLines() async {
        let services = FakeDeviceServices()
        services.consoleLines.value = ["Launched", "network: GET /home", "NETWORK: 200 OK", "done"]
        let console = ConsoleModel(service: services)
        XCTAssertFalse(console.isVisible)

        console.start(bundleIdentifier: "com.example.sample", on: Sample.phone)
        XCTAssertTrue(console.isRunning)
        await console.waitUntilFinished()

        XCTAssertFalse(console.isRunning)
        XCTAssertEqual(console.title, "com.example.sample on Test iPhone")
        XCTAssertEqual(console.lines.map(\.text), services.consoleLines.value)
        console.filter = "network"
        XCTAssertEqual(console.visibleLines.map(\.id), [1, 2])

        console.clear()
        XCTAssertFalse(console.isVisible)
    }

    func testConsoleKeepsOnlyTheNewestLines() async {
        let services = FakeDeviceServices()
        services.consoleLines.value = (0..<(ConsoleModel.lineLimit + 10)).map { "line \($0)" }
        let console = ConsoleModel(service: services)

        console.start(bundleIdentifier: "com.example.sample", on: Sample.phone)
        await console.waitUntilFinished()

        XCTAssertEqual(console.lines.count, ConsoleModel.lineLimit)
        XCTAssertEqual(console.lines.first?.text, "line 10")
    }

    func testConsoleThatFailsShowsTheReason() async {
        let services = FakeDeviceServices()
        services.consoleFailure.value = .toolFailed(tool: "xcrun devicectl", exitCode: 1, message: "The app is not installed.")
        let console = ConsoleModel(service: services)

        console.start(bundleIdentifier: "com.example.sample", on: Sample.phone)
        await console.waitUntilFinished()

        XCTAssertEqual(console.failure, "xcrun devicectl failed (exit 1). The app is not installed.")
        XCTAssertTrue(console.isVisible)
    }
}

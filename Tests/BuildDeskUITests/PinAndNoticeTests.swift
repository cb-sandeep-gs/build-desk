import BuildDeskCore
@testable import BuildDeskUI
import XCTest

/// Records what would have been shown as notifications.
struct FakeNotifier: RunNotifying {
    let notices = Locked<[RunNotice]>([])

    func post(_ notice: RunNotice) async { notices.value += [notice] }
}

@MainActor
final class PinTests: XCTestCase {
    private func makeApp(_ store: TestStore, builder: FakeBuilder = FakeBuilder(), discovery: FakeDiscovery = FakeDiscovery()) -> AppModel {
        let environment = AppEnvironment(reader: FakeReader(), discovery: discovery, builder: builder, isXcodeOpen: { false })
        return AppModel(environment: environment, store: store.make())
    }

    private let stagingOnSimulator = PinnedRun(
        project: Sample.projectURL, scheme: "SampleWidget", configuration: "Staging",
        deviceID: Sample.simulator.id, deviceName: Sample.simulator.name
    )

    func testPinningTheSelectionIsRememberedAndCanBeUndone() async {
        let store = TestStore()
        defer { store.remove() }
        let app = makeApp(store)
        XCTAssertNil(app.pinForSelection)

        await app.open(Sample.projectURL)
        await app.refreshEnvironment()
        app.togglePinForSelection()

        XCTAssertTrue(app.isSelectionPinned)
        XCTAssertEqual(app.pins.map(\.scheme), ["Sample"])
        XCTAssertEqual(app.pins.first?.deviceName, "Test iPhone")
        // A new launch of the app finds the pin again.
        XCTAssertEqual(makeApp(store).pins, app.pins)

        // Another configuration of the same scheme is a different pin.
        app.project?.selectedConfiguration = "Staging"
        XCTAssertFalse(app.isSelectionPinned)
        app.togglePinForSelection()
        XCTAssertEqual(app.pins.count, 2)

        app.togglePinForSelection()
        XCTAssertEqual(app.pins.map(\.configuration), ["Debug"])
    }

    func testRunningAPinOpensItsProjectAndSelectsEverything() async {
        let store = TestStore()
        defer { store.remove() }
        let builder = FakeBuilder()
        builder.events.value = Sample.successfulRun
        let app = makeApp(store, builder: builder)

        // No project is open and the device list has not been loaded.
        await app.run(stagingOnSimulator)
        await app.run.waitUntilFinished()

        XCTAssertNil(app.pinError)
        let request = builder.requests.value.first
        XCTAssertEqual(request?.scheme, "SampleWidget")
        XCTAssertEqual(request?.configuration, "Staging")
        XCTAssertEqual(request?.device, Sample.simulator)
        XCTAssertEqual(request?.builds, true)
        XCTAssertEqual(request?.installs, true)
        XCTAssertEqual(app.project?.selectedSchemeName, "SampleWidget")
    }

    func testAPinThatCannotRunSaysWhy() async {
        let store = TestStore()
        defer { store.remove() }
        let builder = FakeBuilder()
        let app = makeApp(store, builder: builder)

        let offline = PinnedRun(
            project: Sample.projectURL, scheme: "Sample", configuration: "Debug",
            deviceID: Sample.offlinePhone.id, deviceName: Sample.offlinePhone.name
        )
        await app.run(offline)
        XCTAssertEqual(app.pinError, "Old iPhone is not connected. Connect it with a cable and unlock it.")

        let gone = PinnedRun(
            project: Sample.projectURL, scheme: "Removed", configuration: "Debug",
            deviceID: Sample.phone.id, deviceName: Sample.phone.name
        )
        await app.run(gone)
        XCTAssertEqual(app.pinError, "The scheme Removed is no longer in Sample.")

        XCTAssertTrue(builder.requests.value.isEmpty)
        XCTAssertNotNil(app.device(for: offline))
        app.remove(offline)
    }
}

@MainActor
final class RunModeAndNoticeTests: XCTestCase {
    private func makeApp(
        _ store: TestStore, builder: FakeBuilder, notifier: FakeNotifier = FakeNotifier(), isActive: Bool = false
    ) async -> AppModel {
        let environment = AppEnvironment(
            reader: FakeReader(), discovery: FakeDiscovery(), builder: builder, isXcodeOpen: { false },
            notifier: notifier, isAppActive: { isActive }
        )
        let app = AppModel(environment: environment, store: store.make())
        await app.open(Sample.projectURL)
        await app.refreshEnvironment()
        return app
    }

    func testEachModeAsksForTheRightSteps() async {
        let store = TestStore()
        defer { store.remove() }
        let builder = FakeBuilder()
        let app = await makeApp(store, builder: builder)

        for mode in [RunMode.buildAndInstall, .buildOnly, .installOnly] {
            app.runSelected(mode)
            await app.run.waitUntilFinished()
        }
        XCTAssertEqual(builder.requests.value.map(\.builds), [true, true, false])
        XCTAssertEqual(builder.requests.value.map(\.installs), [true, false, true])
        XCTAssertEqual(app.run.steps, [.locate, .install, .launch])

        // A framework has nothing to install, so install-only does nothing at all.
        app.project?.selectedSchemeName = "SampleKit"
        app.runSelected(.installOnly)
        XCTAssertEqual(builder.requests.value.count, 3)
    }

    func testAFinishedRunIsAnnouncedOnlyInTheBackground() async {
        let store = TestStore()
        defer { store.remove() }
        let builder = FakeBuilder()
        builder.events.value = Sample.successfulRun

        let background = FakeNotifier()
        let app = await makeApp(store, builder: builder, notifier: background, isActive: false)
        app.runSelected(.buildAndInstall)
        await waitUntil { !background.notices.value.isEmpty }
        XCTAssertEqual(background.notices.value.map(\.title), ["Sample is ready"])
        XCTAssertTrue(background.notices.value[0].body.hasPrefix("Installed and running on Test iPhone in "))

        // With the window in front, the result is already on screen.
        let foreground = FakeNotifier()
        let frontApp = await makeApp(store, builder: builder, notifier: foreground, isActive: true)
        frontApp.runSelected(.buildAndInstall)
        await frontApp.run.waitUntilFinished()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(foreground.notices.value.isEmpty)
    }

    func testFailuresAreAnnouncedAndStopsAreNot() async {
        let store = TestStore()
        defer { store.remove() }
        let failing = FakeBuilder()
        failing.events.value = [.stepStarted(.build)]
        failing.failure.value = .stepFailed(step: .install, message: "The device is locked.")
        let notifier = FakeNotifier()
        let app = await makeApp(store, builder: failing, notifier: notifier)

        app.runSelected(.buildAndInstall)
        await waitUntil { !notifier.notices.value.isEmpty }
        XCTAssertEqual(notifier.notices.value, [
            RunNotice(title: "Sample failed", body: "The install step failed. The device is locked."),
        ])

        let hanging = FakeBuilder()
        hanging.events.value = [.stepStarted(.build)]
        hanging.hangs.value = true
        let quiet = FakeNotifier()
        let stoppedApp = await makeApp(store, builder: hanging, notifier: quiet)
        stoppedApp.runSelected(.buildAndInstall)
        await waitUntil { stoppedApp.run.statuses[.build] == .running }
        stoppedApp.run.stop()
        await stoppedApp.run.waitUntilFinished()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(stoppedApp.run.phase, .stopped)
        XCTAssertTrue(quiet.notices.value.isEmpty)
    }
}

import BuildDeskCore
@testable import BuildDeskUI
import XCTest

@MainActor
final class LaunchOptionsModelTests: XCTestCase {
    private func makeApp(
        _ store: TestStore, builder: FakeBuilder = FakeBuilder(), services: FakeDeviceServices = FakeDeviceServices()
    ) async -> AppModel {
        let environment = AppEnvironment(
            reader: FakeReader(), discovery: FakeDiscovery(), builder: builder, isXcodeOpen: { false },
            deviceApps: services
        )
        let app = AppModel(environment: environment, store: store.make())
        await app.open(Sample.projectURL)
        await app.refreshEnvironment()
        return app
    }

    func testEachSchemeKeepsItsOwnOptionsAcrossLaunches() async {
        let store = TestStore()
        defer { store.remove() }
        let app = await makeApp(store)
        XCTAssertTrue(app.launchTextsForSelection.isEmpty)

        app.launchTextsForSelection.arguments = "-skipOnboarding"
        app.launchTextsForSelection.url = "sample://cart"
        app.project?.selectedSchemeName = "SampleWatch"
        XCTAssertTrue(app.launchTextsForSelection.isEmpty)

        let reopened = await makeApp(store)
        XCTAssertEqual(reopened.project?.selectedSchemeName, "SampleWatch")
        reopened.project?.selectedSchemeName = "Sample"
        XCTAssertEqual(reopened.launchTextsForSelection, LaunchTexts(arguments: "-skipOnboarding", url: "sample://cart"))

        // Clearing the fields leaves nothing stored.
        reopened.launchTextsForSelection = LaunchTexts()
        XCTAssertTrue(store.make().launchTexts.isEmpty)
    }

    func testARunAndTheConsoleUseTheOptions() async {
        let store = TestStore()
        defer { store.remove() }
        let builder = FakeBuilder()
        builder.events.value = Sample.successfulRun
        let services = FakeDeviceServices()
        let app = await makeApp(store, builder: builder, services: services)
        app.launchTextsForSelection = LaunchTexts(arguments: "-level 3", environment: "API_HOST=staging.example.com")
        let expected = LaunchOptions(arguments: ["-level", "3"], environment: ["API_HOST": "staging.example.com"])

        app.runSelected(.buildAndInstall)
        await waitUntil { app.lastInstall != nil }
        app.openConsoleForSelection()
        await app.console.waitUntilFinished()

        XCTAssertEqual(builder.requests.value.first?.launchOptions, expected)
        XCTAssertEqual(services.consoleOptions.value, [expected])
    }

    func testOptionsThatCannotBeReadBlockTheRunWithTheReason() async {
        let store = TestStore()
        defer { store.remove() }
        let builder = FakeBuilder()
        let app = await makeApp(store, builder: builder)

        app.launchTextsForSelection.environment = "DEBUG"
        XCTAssertEqual(app.runBlocker, "\"DEBUG\" is not a variable. Write each one as NAME=value.")
        app.runSelected(.buildAndInstall)
        XCTAssertTrue(builder.requests.value.isEmpty)

        app.launchTextsForSelection.environment = "DEBUG=1"
        XCTAssertNil(app.runBlocker)
    }

    func testAPinKeepsItsOptionsAndTheSameSchemeCanBePinnedWithAndWithout() async {
        let store = TestStore()
        defer { store.remove() }
        let builder = FakeBuilder()
        builder.events.value = Sample.successfulRun
        let app = await makeApp(store, builder: builder)

        app.togglePinForSelection()
        app.launchTextsForSelection.arguments = "-skipOnboarding"
        XCTAssertFalse(app.isSelectionPinned)
        app.togglePinForSelection()
        XCTAssertEqual(app.pins.map(\.launchOptions.arguments), [[], ["-skipOnboarding"]])

        // Running the plain pin clears the fields; running the other brings its options back.
        await app.run(app.pins[0])
        await app.run.waitUntilFinished()
        XCTAssertTrue(app.launchTextsForSelection.isEmpty)
        await app.run(app.pins[1])
        await app.run.waitUntilFinished()
        XCTAssertEqual(app.launchTextsForSelection.arguments, "-skipOnboarding")
        XCTAssertEqual(builder.requests.value.map(\.launchOptions.arguments), [[], ["-skipOnboarding"]])
    }

    func testPinsSavedBeforeLaunchOptionsExistedStillLoad() throws {
        let old = #"""
        [{"project":"file:///projects/Sample.xcodeproj","scheme":"Sample","configuration":"Debug",
          "deviceID":"PHONE","deviceName":"Test iPhone"}]
        """#
        let pins = try JSONDecoder().decode([PinnedRun].self, from: Data(old.utf8))

        XCTAssertEqual(pins.first?.scheme, "Sample")
        XCTAssertEqual(pins.first?.launchOptions, LaunchOptions())
    }
}

import BuildDeskCore
@testable import BuildDeskUI
import XCTest

@MainActor
final class ProjectConfigModelTests: XCTestCase {
    private func model(_ store: TestStore, config: ProjectConfig, problem: String? = nil) async throws -> ProjectModel {
        let reader = FakeReader()
        let container = try Sample.container()
        reader.quick.value = .success(Sample.snapshot(of: container, config: config, configProblem: problem))
        let model = ProjectModel(container: container, reader: reader, store: store.make())
        await model.load()
        return model
    }

    func testFavoritesComeFirstInTheProjectsOrderAndAreNotRepeated() async throws {
        let store = TestStore()
        defer { store.remove() }
        let config = ProjectConfig(favoriteSchemes: ["SampleWidget", "Sample", "Gone"])
        let model = try await model(store, config: config)

        XCTAssertEqual(model.groups.map(\.title), ["Favorites", "Apps", "Frameworks", "Tests"])
        XCTAssertEqual(model.groups[0].schemes.map(\.name), ["SampleWidget", "Sample"])
        XCTAssertEqual(model.groups[1].schemes.map(\.name), ["SampleWatch"])
        // With nothing remembered and no default named, the first favorite is where the window starts.
        XCTAssertEqual(model.selectedSchemeName, "SampleWidget")
    }

    func testHiddenSchemesAreLeftOutUntilAskedFor() async throws {
        let store = TestStore()
        defer { store.remove() }
        let model = try await model(store, config: ProjectConfig(hiddenSchemes: ["*Tests", "SampleKit"]))

        XCTAssertEqual(model.hiddenSchemeCount, 2)
        XCTAssertEqual(model.groups.map(\.title), ["Apps", "Extensions"])
        // The filter does not reach hidden schemes either.
        model.filter = "kit"
        XCTAssertTrue(model.groups.isEmpty)

        model.showsHiddenSchemes = true
        XCTAssertEqual(model.groups.flatMap(\.schemes).map(\.name), ["SampleKit"])
    }

    func testProjectDefaultsApplyUntilThePersonChoosesSomethingElse() async throws {
        let store = TestStore()
        defer { store.remove() }
        let config = ProjectConfig(favoriteSchemes: ["Sample"], defaultScheme: "SampleWatch", defaultConfiguration: "Staging")
        let first = try await model(store, config: config)
        XCTAssertEqual(first.selectedSchemeName, "SampleWatch")
        XCTAssertEqual(first.selectedConfiguration, "Staging")

        first.selectedSchemeName = "SampleKit"
        first.selectedConfiguration = "Release"
        let reopened = try await self.model(store, config: config)
        XCTAssertEqual(reopened.selectedSchemeName, "SampleKit")
        XCTAssertEqual(reopened.selectedConfiguration, "Release")
    }

    func testDefaultsThatTheProjectDoesNotHaveAreIgnored() async throws {
        let store = TestStore()
        defer { store.remove() }
        let config = ProjectConfig(defaultScheme: "Removed", defaultConfiguration: "Nightly")
        let model = try await model(store, config: config, problem: "a problem")

        XCTAssertEqual(model.selectedSchemeName, "Sample")
        XCTAssertEqual(model.selectedConfiguration, "Debug")
        XCTAssertEqual(model.snapshot?.configProblem, "a problem")
    }
}

@MainActor
final class DeviceDoctorModelTests: XCTestCase {
    private func makeApp(_ store: TestStore, _ discovery: FakeDiscovery) async -> AppModel {
        let environment = AppEnvironment(reader: FakeReader(), discovery: discovery, builder: FakeBuilder(), isXcodeOpen: { false })
        let app = AppModel(environment: environment, store: store.make())
        await app.open(Sample.projectURL)
        await app.refreshEnvironment()
        return app
    }

    func testALockedDeviceIsAHintNotABlocker() async {
        let store = TestStore()
        defer { store.remove() }
        let discovery = FakeDiscovery()
        discovery.lockedIDs.value = [Sample.phone.id]
        let app = await makeApp(store, discovery)

        XCTAssertNil(app.runBlocker)
        XCTAssertEqual(app.deviceHint, "Test iPhone is locked. Unlock it so the app can be opened after the install.")

        // Unlocked by the next refresh: the hint goes away.
        discovery.lockedIDs.value = []
        await app.refreshEnvironment()
        XCTAssertNil(app.deviceHint)
    }

    func testEachDeviceProblemBlocksWithItsOwnInstruction() async {
        let store = TestStore()
        defer { store.remove() }
        let untrusted = Device(
            id: "NEW", name: "New iPhone", model: "iPhone 17", platform: "iOS", osVersion: "27.2",
            kind: .physical, connection: .wired, isReady: false, isBooted: true, issue: .notPaired
        )
        let noDeveloperMode = Device(
            id: "QA", name: "QA iPhone", model: "iPhone 17", platform: "iOS", osVersion: "27.2",
            kind: .physical, connection: .wired, isReady: false, isBooted: true, issue: .developerModeOff
        )
        let discovery = FakeDiscovery()
        discovery.result.value = .success([untrusted, noDeveloperMode])
        let app = await makeApp(store, discovery)

        app.devices.selectedDeviceID = untrusted.id
        XCTAssertEqual(app.runBlocker, "New iPhone doesn't trust this Mac yet. Unlock it, reconnect the cable and tap Trust.")
        app.devices.selectedDeviceID = noDeveloperMode.id
        XCTAssertEqual(
            app.runBlocker,
            "Developer Mode is off on QA iPhone. Turn it on in Settings ▸ Privacy & Security ▸ Developer Mode, then restart the device."
        )
        XCTAssertEqual(noDeveloperMode.detail, "iOS 27.2 · Developer Mode off")
    }
}

import BuildDeskCore
@testable import BuildDeskUI
import XCTest

@MainActor
final class DeviceToolsModelTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/saved")

    private func makeApp(_ store: TestStore, tools: FakeDeviceTools, builder: FakeBuilder = FakeBuilder()) async -> AppModel {
        let environment = AppEnvironment(
            reader: FakeReader(), discovery: FakeDiscovery(), builder: builder, isXcodeOpen: { false }, deviceTools: tools
        )
        let app = AppModel(environment: environment, store: store.make())
        await app.open(Sample.projectURL)
        await app.refreshEnvironment()
        return app
    }

    func testAScreenshotIsSavedWithTheDeviceNameAndTime() async {
        let store = TestStore()
        defer { store.remove() }
        let tools = FakeDeviceTools()
        let app = await makeApp(store, tools: tools)
        XCTAssertTrue(app.canUseDeviceTools)

        await app.takeScreenshot(in: folder)

        XCTAssertEqual(tools.calls.value.count, 1)
        XCTAssertTrue(tools.calls.value[0].hasPrefix("screenshot of Test iPhone to Test iPhone 20"))
        XCTAssertTrue(tools.calls.value[0].hasSuffix(".png"))
        XCTAssertEqual(app.deviceToolMessage, "Screenshot of Test iPhone saved.")
        XCTAssertEqual(app.deviceToolResult?.deletingLastPathComponent().path, "/saved")
        XCTAssertFalse(app.isUsingDeviceTool)
    }

    func testAppDataNeedsAnInstallFromBuildDeskFirst() async {
        let store = TestStore()
        defer { store.remove() }
        let tools = FakeDeviceTools()
        let builder = FakeBuilder()
        builder.events.value = Sample.successfulRun
        let app = await makeApp(store, tools: tools, builder: builder)

        // Which app to copy is not known yet.
        await app.downloadAppData(to: folder)
        XCTAssertTrue(tools.calls.value.isEmpty)

        app.runSelected(.buildAndInstall)
        await waitUntil { app.lastInstall != nil }
        await app.downloadAppData(to: folder)

        XCTAssertEqual(tools.calls.value.count, 1)
        XCTAssertTrue(tools.calls.value[0].hasPrefix("data of com.example.sample from Test iPhone to Sample data 20"))
        XCTAssertEqual(app.deviceToolMessage, "App data of Sample copied from Test iPhone.")
    }

    func testOnlyTheNewestCrashLogsAreSavedAndNoneIsSaidPlainly() async {
        let store = TestStore()
        defer { store.remove() }
        let tools = FakeDeviceTools()
        let app = await makeApp(store, tools: tools)

        await app.saveCrashLogs(to: folder)
        XCTAssertEqual(app.deviceToolMessage, "No crash logs for Sample on Test iPhone.")
        XCTAssertNil(app.deviceToolResult)

        tools.logs.value = (0..<(AppModel.crashLogLimit + 5)).map { CrashLog(name: "Sample-\($0).ips") }
        await app.saveCrashLogs(to: folder)

        // Named after the process the scheme runs, not the scheme or the bundle identifier.
        let lookups = tools.calls.value.filter { $0.hasPrefix("crash logs") }
        XCTAssertEqual(lookups, Array(repeating: "crash logs of Sample on Test iPhone", count: 2))
        let copy = "copy \(AppModel.crashLogLimit) logs from Test iPhone to Sample crash logs 20"
        XCTAssertTrue(tools.calls.value.last?.hasPrefix(copy) == true)
        XCTAssertEqual(app.deviceToolMessage, "\(AppModel.crashLogLimit) crash logs of Sample saved.")
    }

    func testAFailureIsShownAndADeviceThatIsAwayIsNotAsked() async {
        let store = TestStore()
        defer { store.remove() }
        let tools = FakeDeviceTools()
        tools.failure.value = .toolFailed(tool: "xcrun devicectl", exitCode: 1, message: "The device is locked.")
        let app = await makeApp(store, tools: tools)

        await app.takeScreenshot(in: folder)
        XCTAssertEqual(app.deviceToolMessage, "xcrun devicectl failed (exit 1). The device is locked.")
        XCTAssertNil(app.deviceToolResult)

        tools.failure.value = nil
        app.devices.selectedDeviceID = Sample.offlinePhone.id
        XCTAssertFalse(app.canUseDeviceTools)
        await app.takeScreenshot(in: folder)
        XCTAssertTrue(tools.calls.value.isEmpty)
    }

    func testFileStampIsSafeInAFileNameAndSortsByTime() {
        let stamp = AppModel.fileStamp(Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(stamp.count, "2027-01-15 at 08.00.00".count)
        XCTAssertFalse(stamp.contains(":"))
        XCTAssertFalse(stamp.contains("/"))
    }
}

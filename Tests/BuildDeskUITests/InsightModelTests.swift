import BuildDeskCore
@testable import BuildDeskUI
import XCTest

@MainActor
final class InsightModelTests: XCTestCase {
    private func makeApp(
        _ store: TestStore,
        builder: FakeBuilder,
        history: MemoryRunHistoryStore = MemoryRunHistoryStore(),
        folders: FakeBuildFolders = FakeBuildFolders(),
        isXcodeOpen: Bool = false
    ) async -> AppModel {
        let environment = AppEnvironment(
            reader: FakeReader(), discovery: FakeDiscovery(), builder: builder, isXcodeOpen: { isXcodeOpen },
            source: FakeDeviceServices(), history: history, buildFolders: folders
        )
        let app = AppModel(environment: environment, store: store.make())
        await app.open(Sample.projectURL)
        await app.refreshEnvironment()
        return app
    }

    /// A successful run that reports the given warnings.
    private func run(with warnings: [Diagnostic]) -> [PipelineEvent] {
        let summary = RunSummary(
            product: Sample.summary.product, taskCount: 3, warnings: warnings, secondsByStep: [.build: 2], logFile: nil
        )
        return Array(Sample.successfulRun.dropLast()) + [.finished(summary)]
    }

    func testEachRunIsRecordedWithItsNumbersAndSource() async {
        let store = TestStore()
        defer { store.remove() }
        let builder = FakeBuilder()
        builder.events.value = Sample.successfulRun
        let app = await makeApp(store, builder: builder)
        XCTAssertTrue(app.history.isEmpty)

        app.runSelected(.buildAndInstall)
        await waitUntil { app.history.count == 1 }

        let record = app.history[0]
        XCTAssertEqual(record.scheme, "Sample")
        XCTAssertEqual(record.configuration, "Debug")
        XCTAssertEqual(record.deviceName, "Test iPhone")
        XCTAssertEqual(record.action, .buildAndInstall)
        XCTAssertEqual(record.result, .succeeded)
        XCTAssertEqual(record.buildSeconds, 2)
        XCTAssertEqual(record.taskCount, 3)
        XCTAssertEqual(record.warningCount, 1)
        XCTAssertEqual(record.source?.commit, "1a2b3c4")
        // History is per scheme in the window.
        XCTAssertEqual(app.historyForSelectedScheme.count, 1)
        app.project?.selectedSchemeName = "SampleKit"
        XCTAssertTrue(app.historyForSelectedScheme.isEmpty)
    }

    func testNewWarningsAreThoseNoEarlierBuildHad() async {
        let store = TestStore()
        defer { store.remove() }
        let builder = FakeBuilder()
        let unused = Diagnostic(severity: .warning, message: "unused variable", file: "/src/Cart.swift", line: 9, column: 5)
        let app = await makeApp(store, builder: builder)

        // The first build has nothing to compare with.
        builder.events.value = run(with: [Sample.deprecation])
        app.runSelected(.buildAndInstall)
        await waitUntil { app.history.count == 1 }
        XCTAssertNil(app.newWarnings)
        XCTAssertNil(app.history[0].newWarningCount)

        builder.events.value = run(with: [Sample.deprecation, unused])
        app.runSelected(.buildAndInstall)
        await waitUntil { app.history.count == 2 }
        XCTAssertEqual(app.newWarnings, [unused])
        XCTAssertEqual(app.history[0].newWarningCount, 1)

        // An incremental build that prints only an old warning has nothing new, and the warning
        // it did not print is still known afterwards.
        builder.events.value = run(with: [unused])
        app.runSelected(.buildAndInstall)
        await waitUntil { app.history.count == 3 }
        XCTAssertEqual(app.newWarnings, [])
        builder.events.value = run(with: [Sample.deprecation])
        app.runSelected(.buildAndInstall)
        await waitUntil { app.history.count == 4 }
        XCTAssertEqual(app.newWarnings, [])
    }

    func testFailedAndStoppedRunsAreRecordedWithoutTouchingKnownWarnings() async {
        let store = TestStore()
        defer { store.remove() }
        let history = MemoryRunHistoryStore()
        let failing = FakeBuilder()
        failing.events.value = [.stepStarted(.build)]
        failing.failure.value = .buildFailed(errors: [], logFile: nil)
        let app = await makeApp(store, builder: failing, history: history)

        app.runSelected(.buildOnly)
        await waitUntil { app.history.count == 1 }

        XCTAssertEqual(app.history[0].result, .failed)
        XCTAssertEqual(app.history[0].action, .buildOnly)
        XCTAssertNil(app.history[0].buildSeconds)
        XCTAssertNil(app.newWarnings)
        let known = await history.knownWarnings(for: "/projects/Sample.xcodeproj|Sample|Debug")
        XCTAssertNil(known)
    }

    func testHistoryIsLoadedWhenAProjectOpens() async {
        let store = TestStore()
        defer { store.remove() }
        let earlier = RunRecord(
            date: Date(timeIntervalSince1970: 1_800_000_000), projectPath: Sample.projectURL.path, scheme: "Sample",
            configuration: "Debug", deviceName: "Test iPhone", deviceKind: .physical, action: .buildOnly, result: .succeeded,
            totalSeconds: 30, buildSeconds: 30, taskCount: 10, warningCount: 0, newWarningCount: nil, errorCount: 0, source: nil
        )
        let app = await makeApp(store, builder: FakeBuilder(), history: MemoryRunHistoryStore(records: [earlier]))

        XCTAssertEqual(app.history, [earlier])
        XCTAssertEqual(app.buildFolder?.buildBytes, 4_500_000_000)
    }

    func testCleaningFreesTheFolderAndSaysWhatItCosts() async {
        let store = TestStore()
        defer { store.remove() }
        let folders = FakeBuildFolders()
        let app = await makeApp(store, builder: FakeBuilder(), folders: folders)

        await app.cleanBuildFolder()

        XCTAssertEqual(folders.cleaned.value, 1)
        XCTAssertNil(app.buildFolder?.buildBytes)
        XCTAssertEqual(app.buildFolderMessage, "4.5 GB freed. The next build will be a full one.")
        XCTAssertFalse(app.isCleaningBuildFolder)
    }

    func testCleaningIsRefusedWhileXcodeIsOpenOrABuildRuns() async {
        let store = TestStore()
        defer { store.remove() }
        let folders = FakeBuildFolders()
        let withXcode = await makeApp(store, builder: FakeBuilder(), folders: folders, isXcodeOpen: true)
        await withXcode.cleanBuildFolder()
        XCTAssertEqual(withXcode.buildFolderMessage, "Xcode is open. Quit it first, or use Product ▸ Clean Build Folder in Xcode.")

        let hanging = FakeBuilder()
        hanging.events.value = [.stepStarted(.build)]
        hanging.hangs.value = true
        let building = await makeApp(store, builder: hanging, folders: folders)
        building.runSelected(.buildOnly)
        await building.cleanBuildFolder()
        XCTAssertEqual(building.buildFolderMessage, "Wait for the running build to finish.")
        building.run.stop()

        XCTAssertEqual(folders.cleaned.value, 0)
    }

    func testAFailedCleanSaysWhy() async {
        let store = TestStore()
        defer { store.remove() }
        let folders = FakeBuildFolders()
        folders.failure.value = .toolFailed(tool: "rm", exitCode: 1, message: "Permission denied")
        let app = await makeApp(store, builder: FakeBuilder(), folders: folders)

        await app.cleanBuildFolder()

        XCTAssertEqual(app.buildFolderMessage, "Couldn't clean the build folder: rm failed (exit 1). Permission denied")
        XCTAssertEqual(app.buildFolder?.buildBytes, 4_500_000_000)
    }
}

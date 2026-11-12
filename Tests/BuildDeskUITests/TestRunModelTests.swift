import BuildDeskCore
@testable import BuildDeskUI
import XCTest

@MainActor
final class TestRunModelTests: XCTestCase {
    private func makeApp(
        _ store: TestStore, tester: FakeTester, builder: FakeBuilder = FakeBuilder(), notifier: FakeNotifier = FakeNotifier()
    ) async -> AppModel {
        let environment = AppEnvironment(
            reader: FakeReader(), discovery: FakeDiscovery(), builder: builder, isXcodeOpen: { false },
            notifier: notifier, isAppActive: { false }, tester: tester
        )
        let app = AppModel(environment: environment, store: store.make())
        await app.open(Sample.projectURL)
        await app.refreshEnvironment()
        return app
    }

    private let finishedRun: [TestEvent] = [
        .build(.task(name: "SwiftCompile", target: "Sample")),
        .testingStarted,
        .caseFinished(suite: "HomeTests", name: "testLoads", status: .passed),
        .caseFinished(suite: "CartTests", name: "testTotal", status: .failed),
        .finished(Sample.testSummary),
    ]

    func testARunCountsLiveAndEndsWithResultsFailuresFirst() async {
        let store = TestStore()
        defer { store.remove() }
        let tester = FakeTester()
        tester.events.value = finishedRun
        let app = await makeApp(store, tester: tester)
        XCTAssertTrue(app.canTestSelection)

        app.project?.selectedConfiguration = "Staging"
        app.runTests()
        XCTAssertTrue(app.tests.isRunning)
        await app.tests.waitUntilFinished()

        XCTAssertEqual(app.tests.phase, .finished)
        XCTAssertEqual(app.tests.buildTaskCount, 1)
        XCTAssertEqual(app.tests.liveCounts, [.passed: 1, .failed: 1])
        XCTAssertEqual(app.tests.latestTest, "CartTests.testTotal")
        XCTAssertEqual(app.tests.summary, Sample.testSummary)
        // The class with a failure comes first.
        XCTAssertEqual(app.tests.suites.map(\.suite), ["CartTests", "HomeTests"])
        XCTAssertEqual(app.tests.suites.first?.failedCount, 1)
        XCTAssertEqual(app.tests.logFile?.path, "/logs/tests.log")
        let request = tester.requests.value.first
        XCTAssertEqual(request?.scheme, "Sample")
        XCTAssertEqual(request?.configuration, "Staging")
        XCTAssertEqual(request?.device, Sample.phone)
        XCTAssertEqual(request?.onlyTesting, [])
    }

    func testRerunFailedRunsOnlyWhatFailed() async {
        let store = TestStore()
        defer { store.remove() }
        let tester = FakeTester()
        tester.events.value = finishedRun
        let app = await makeApp(store, tester: tester)

        app.rerunFailedTests()
        XCTAssertTrue(tester.requests.value.isEmpty)

        app.runTests()
        await app.tests.waitUntilFinished()
        app.rerunFailedTests()
        await app.tests.waitUntilFinished()

        XCTAssertEqual(tester.requests.value.map(\.onlyTesting), [[], ["SampleTests/CartTests/testTotal"]])
    }

    func testOnlySchemesWithTestsCanBeTestedAndNotDuringABuild() async {
        let store = TestStore()
        defer { store.remove() }
        let tester = FakeTester()
        let hanging = FakeBuilder()
        hanging.events.value = [.stepStarted(.build)]
        hanging.hangs.value = true
        let app = await makeApp(store, tester: tester, builder: hanging)

        app.project?.selectedSchemeName = "SampleKit"
        XCTAssertFalse(app.canTestSelection)
        app.runTests()

        app.project?.selectedSchemeName = "Sample"
        app.runSelected(.buildOnly)
        app.runTests()
        app.run.stop()
        await app.run.waitUntilFinished()

        XCTAssertTrue(tester.requests.value.isEmpty)
    }

    func testABuildCannotStartWhileTestsRun() async {
        let store = TestStore()
        defer { store.remove() }
        let tester = FakeTester()
        tester.events.value = [.testingStarted]
        tester.hangs.value = true
        let builder = FakeBuilder()
        let app = await makeApp(store, tester: tester, builder: builder)

        app.runTests()
        await waitUntil { app.tests.phase == .testing }
        XCTAssertEqual(app.runBlocker, "Tests are running.")
        app.runSelected(.buildAndInstall)
        XCTAssertTrue(builder.requests.value.isEmpty)

        app.tests.stop()
        await app.tests.waitUntilFinished()
        XCTAssertEqual(app.tests.phase, .stopped)
        XCTAssertNil(app.runBlocker)
    }

    func testABrokenBuildShowsItsErrors() async {
        let store = TestStore()
        defer { store.remove() }
        let tester = FakeTester()
        let error = Diagnostic(severity: .error, message: "cannot find 'total' in scope", file: "/src/Cart.swift", line: 3, column: 1)
        tester.failure.value = .buildFailed(errors: [error], logFile: "/logs/tests.log")
        let app = await makeApp(store, tester: tester)

        app.runTests()
        await app.tests.waitUntilFinished()

        XCTAssertEqual(app.tests.phase, .failed("The build failed with 1 error. First: cannot find 'total' in scope"))
        XCTAssertEqual(app.tests.errors, [error])
        XCTAssertEqual(app.tests.logFile?.path, "/logs/tests.log")
        XCTAssertTrue(app.tests.suites.isEmpty)
    }

    func testAFinishedTestRunIsAnnouncedInTheBackground() async {
        let store = TestStore()
        defer { store.remove() }
        let tester = FakeTester()
        tester.events.value = finishedRun
        let notifier = FakeNotifier()
        let app = await makeApp(store, tester: tester, notifier: notifier)

        app.runTests()
        await waitUntil { !notifier.notices.value.isEmpty }

        XCTAssertEqual(notifier.notices.value, [RunNotice(title: "Sample tests failed", body: "1 passed, 1 failed in 12 s.")])
    }
}

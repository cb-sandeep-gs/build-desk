import BuildDeskCore
@testable import BuildDeskUI
import XCTest

@MainActor
final class ReleaseWatchModelTests: XCTestCase {
    private let withStore = ReleaseProvider(
        commands: ReleaseCommands(status: ["./tool", "status"], store: ["./tool", "store"]), folder: URL(fileURLWithPath: "/projects")
    )
    private let store = TestStore()
    private let releases = FakeReleases()
    private let notifier = FakeNotifier()
    private var isActive = false

    override func tearDown() {
        store.remove()
        super.tearDown()
    }

    /// An app whose open project can tell its store state; the first reading has a cloud build running.
    private func makeApp(provider: ReleaseProvider? = nil) -> AppModel {
        let environment = AppEnvironment(
            reader: FakeReader(), discovery: FakeDiscovery(), builder: FakeBuilder(), isXcodeOpen: { false },
            notifier: notifier, isAppActive: { [unowned self] in self.isActive }, releases: releases
        )
        let app = AppModel(environment: environment, store: store.make())
        app.release = ReleaseModel(provider: provider ?? withStore, client: releases)
        releases.storeStatus.value = .success(storeStatus(cloud: "running"))
        return app
    }

    private func storeStatus(cloud: String, testing: String? = nil) -> ReleaseStoreStatus {
        ReleaseStoreStatus(connected: true, apps: [
            ReleaseStoreApp(id: "sample", builds: [ReleaseStoreBuild(id: Sample.internalBuild.id, cloud: cloud, testing: testing)]),
        ])
    }

    func testACloudBuildThatEndsIsAnnouncedOnce() async {
        let app = makeApp()

        // The first reading has nothing to compare with.
        await app.releaseWatch.check()
        XCTAssertEqual(notifier.notices.value, [])
        XCTAssertNotNil(app.releaseWatch.lastChecked)

        releases.storeStatus.value = .success(storeStatus(cloud: "succeeded"))
        await app.releaseWatch.check()
        XCTAssertEqual(notifier.notices.value, [
            RunNotice(title: "SampleInternal-4.2.3 is built", body: "Sample: the cloud build succeeded."),
        ])

        // Reading the same state again says nothing more.
        await app.releaseWatch.check()
        XCTAssertEqual(notifier.notices.value.count, 1)

        releases.storeStatus.value = .success(storeStatus(cloud: "succeeded", testing: "In testing"))
        await app.releaseWatch.check()
        XCTAssertEqual(notifier.notices.value.last?.title, "SampleInternal-4.2.3: In testing")
    }

    func testAFailedCloudBuildIsAnnounced() async {
        let app = makeApp()
        await app.releaseWatch.check()

        releases.storeStatus.value = .success(storeStatus(cloud: "failed"))
        await app.releaseWatch.check()

        XCTAssertEqual(notifier.notices.value.map(\.title), ["SampleInternal-4.2.3 failed in the cloud"])
    }

    func testNothingIsAnnouncedToSomeoneLookingAtReleaseMode() async {
        let app = makeApp()
        await app.releaseWatch.check()
        isActive = true
        app.mode = .release

        releases.storeStatus.value = .success(storeStatus(cloud: "succeeded"))
        await app.releaseWatch.check()
        XCTAssertEqual(notifier.notices.value, [])

        // Looking at Build mode is not looking at the release: the next step is announced.
        app.mode = .build
        releases.storeStatus.value = .success(storeStatus(cloud: "succeeded", testing: "In testing"))
        await app.releaseWatch.check()
        XCTAssertEqual(notifier.notices.value.count, 1)
    }

    func testAStoreThatCannotBeReadAnnouncesNothingAndKeepsTheLastReading() async {
        let app = makeApp()
        await app.releaseWatch.check()

        releases.storeStatus.value = .failure(.releaseFailed(message: "The network is down."))
        await app.releaseWatch.check()
        XCTAssertEqual(notifier.notices.value, [])
    }

    func testAProjectWithoutAStoreCommandIsNotWatched() async {
        let app = makeApp(provider: Sample.releaseProvider)
        XCTAssertFalse(app.releaseWatch.canWatch)

        await app.releaseWatch.check()

        XCTAssertEqual(releases.statusCalls.value, 0)
        XCTAssertNil(app.releaseWatch.lastChecked)
    }

    func testTheLoopReadsAtOnceThenWaitsAsLongAsTheStateAsksFor() async {
        let app = makeApp()
        let waits = Locked<[TimeInterval]>([])
        app.releaseWatch.sleep = { seconds in
            waits.value += [seconds]
            // Stands in for the wait: the test decides when the loop goes on.
            try? await Task.sleep(for: .seconds(3600))
        }

        // Not started by opening a project alone; the app's scenes start it.
        app.releaseWatch.restart()
        XCTAssertEqual(releases.statusCalls.value, 0)

        app.releaseWatch.activate()
        await waitUntil { waits.value.count == 1 }
        XCTAssertEqual(releases.storeCalls.value, 1)
        XCTAssertEqual(waits.value, [BuildDeskConstants.ReleaseWatch.activeSeconds])

        // Turning the setting off stops the loop and is remembered.
        app.releaseWatch.isEnabled = false
        XCTAssertFalse(store.make().watchesReleases)
        app.releaseWatch.restart()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(releases.storeCalls.value, 1)
    }

    func testTheMenuShowsOneLinePerAppAboutItsRunningOrNewestBuild() async {
        let app = makeApp()
        XCTAssertEqual(app.release?.menuLines, [])

        await app.releaseWatch.check()

        XCTAssertEqual(app.release?.menuLines, [
            ReleaseMenuLine(id: "sample", title: "Sample 4.2", detail: "SampleInternal-4.2.3 · Building in the cloud", mark: .running),
            ReleaseMenuLine(id: "pro", title: "Sample Pro 2.0", detail: "ProInternal-2.0.1", mark: .none),
        ])

        // Alerts are counted on the app's line.
        releases.storeStatus.value = .success(Sample.storeStatus)
        await app.releaseWatch.check()
        XCTAssertEqual(app.release?.menuLines.first?.detail, "SampleInternal-4.2.3 · In testing · 1 alert")
        XCTAssertEqual(app.release?.menuLines.first?.mark, .succeeded)
    }
}

import BuildDeskCore
@testable import BuildDeskUI
import XCTest

@MainActor
final class NavigationTests: XCTestCase {
    private let store = TestStore()
    private let releases = FakeReleases()
    private let builder = FakeBuilder()
    private let withStore = ReleaseProvider(
        commands: ReleaseCommands(
            status: ["./tool", "status"], plan: ["./tool", "plan"], run: ["./tool", "run"], store: ["./tool", "store"]
        ),
        folder: URL(fileURLWithPath: "/projects")
    )

    override func tearDown() {
        store.remove()
        super.tearDown()
    }

    private func makeApp() async -> AppModel {
        let environment = AppEnvironment(
            reader: FakeReader(), discovery: FakeDiscovery(), builder: builder, isXcodeOpen: { false }, releases: releases
        )
        let app = AppModel(environment: environment, store: store.make())
        await app.open(Sample.projectURL)
        await app.refreshEnvironment()
        app.release = ReleaseModel(provider: withStore, client: releases)
        await app.release?.refresh()
        return app
    }

    func testTheSidebarMovesBetweenPagesAndRemembersEachSelection() async {
        let app = await makeApp()
        app.sidebarSelection = .scheme("Sample")
        XCTAssertEqual(app.mode, .build)
        XCTAssertEqual(app.project?.selectedSchemeName, "Sample")

        app.release?.selectedBuildID = Sample.internalBuild.id
        app.sidebarSelection = .releaseApp("pro")
        XCTAssertEqual(app.mode, .release)
        XCTAssertEqual(app.release?.selectedAppID, "pro")
        // Another app's build is not this app's: the inspector closes.
        XCTAssertNil(app.release?.selectedBuildID)
        XCTAssertEqual(app.sidebarSelection, .releaseApp("pro"))

        app.sidebarSelection = .activity
        XCTAssertEqual(app.mode, .activity)
        XCTAssertEqual(app.sidebarSelection, .activity)

        // Coming back to Build shows the scheme that was there.
        app.mode = .build
        XCTAssertEqual(app.sidebarSelection, .scheme("Sample"))
        XCTAssertEqual(app.releaseApps.map(\.id), ["sample", "pro"])
    }

    func testBuildsAreGroupedByAppVersionAndFiltered() async throws {
        let app = await makeApp()
        let release = try XCTUnwrap(app.release)
        func build(_ version: String, _ track: String?) -> ReleaseBuild {
            ReleaseBuild(id: "B-\(version)-\(track ?? "store")", app: "sample", track: track, kind: track == nil ? .store : .testflight,
                         version: version)
        }
        let store = build("4.1", nil)
        releases.status.value = .success(ReleaseStatus(
            head: nil,
            apps: [ReleaseApp(
                id: "sample", name: "Sample", version: "4.2",
                tracks: [ReleaseTrack(id: "internal", name: "Internal testers"), ReleaseTrack(id: "partner", name: "Partners")],
                store: store
            )],
            builds: [build("4.2.3", "internal"), build("4.2.1", "partner"), store, build("4.1.9", "internal")]
        ))
        releases.storeStatus.value = .success(ReleaseStoreStatus(connected: true, apps: [
            ReleaseStoreApp(id: "sample", builds: [ReleaseStoreBuild(id: "B-4.1.9-internal", cloud: "failed")]),
        ]))
        await release.refresh()

        XCTAssertEqual(release.buildGroups.map(\.id), ["4.2", "4.1"])
        XCTAssertEqual(release.buildGroups.map(\.builds.count), [2, 2])
        XCTAssertEqual(release.buildGroups.map(\.isOnStore), [false, true])
        XCTAssertEqual(release.filters, [.all, .track("internal"), .track("partner"), .failed])
        XCTAssertEqual(release.title(of: .track("partner")), "Partners")

        release.filter = .track("partner")
        XCTAssertEqual(release.filteredBuilds.map(\.version), ["4.2.1"])
        release.filter = .failed
        XCTAssertEqual(release.filteredBuilds.map(\.version), ["4.1.9"])
        XCTAssertEqual(release.stateText(of: release.filteredBuilds[0]), "Cloud build failed")
        XCTAssertEqual(release.stateText(of: store), "Store release")
    }

    func testMarkingABuildAsTheStoreReleaseStartsFromThatBuild() async throws {
        let app = await makeApp()
        let release = try XCTUnwrap(app.release)

        release.beginStoreRelease(of: Sample.internalBuild)

        XCTAssertEqual(release.activeAction?.action.kind, .store)
        XCTAssertEqual(release.activeAction?.action.from, Sample.internalBuild.id)
    }

    func testTheToolbarStatusFollowsTheWorkThenTheRelease() async {
        let app = await makeApp()
        // Nothing was run: where the release stands.
        XCTAssertEqual(app.toolbarStatus, ToolbarStatus(text: "Sample 4.2 · SampleInternal-4.2.3 · In testing · 1 alert", tone: .good))

        builder.hangs.value = true
        app.sidebarSelection = .scheme("Sample")
        app.devices.selectedDeviceID = Sample.phone.id
        app.runSelected(.buildOnly)
        XCTAssertEqual(app.toolbarStatus.tone, .working)
        XCTAssertTrue(app.toolbarStatus.text.hasPrefix("Sample · "))

        app.run.stop()
        await app.run.waitUntilFinished()
        XCTAssertEqual(app.toolbarStatus, ToolbarStatus(text: "Stopped", tone: .neutral))
    }
}

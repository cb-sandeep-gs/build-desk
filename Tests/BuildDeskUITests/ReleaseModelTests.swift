import BuildDeskCore
@testable import BuildDeskUI
import XCTest

@MainActor
final class ReleaseModelTests: XCTestCase {
    func testStatusLoadsAndStartsOnTheFirstApp() async {
        let releases = FakeReleases()
        let model = ReleaseModel(provider: Sample.releaseProvider, client: releases)
        XCTAssertEqual(model.state, .idle)

        await model.refresh()

        XCTAssertEqual(model.selectedApp?.name, "Sample")
        XCTAssertEqual(model.selectedApp?.tracks.map(\.name), ["Internal testers", "Partners"])
        // Only the selected app's builds, newest first as the provider gave them.
        XCTAssertEqual(model.builds.map(\.id), ["SampleInternal-4.2.3", "SampleStore-4.1"])
        XCTAssertEqual(model.trackName(of: Sample.internalBuild), "Internal testers")
        XCTAssertEqual(model.trackName(of: Sample.storeBuild), "Store")
        XCTAssertTrue(model.canAct)
        XCTAssertFalse(model.isRefreshing)
    }

    func testSwitchingAppAndRefreshingKeepsTheChoiceThatStillExists() async {
        let releases = FakeReleases()
        let model = ReleaseModel(provider: Sample.releaseProvider, client: releases)
        await model.refresh()

        model.selectedAppID = "pro"
        model.selectedBuildID = "ProInternal-2.0.1"
        XCTAssertEqual(model.builds.map(\.id), ["ProInternal-2.0.1"])
        await model.refresh()
        XCTAssertEqual(model.selectedAppID, "pro")
        XCTAssertEqual(model.selectedBuildID, "ProInternal-2.0.1")

        // The app and the open build are gone from the next status: fall back, don't point at nothing.
        releases.status.value = .success(ReleaseStatus(
            head: nil, apps: [Sample.releaseStatus.apps[0]], builds: [Sample.internalBuild]
        ))
        await model.refresh()
        XCTAssertEqual(model.selectedAppID, "sample")
        XCTAssertNil(model.selectedBuildID)
        XCTAssertEqual(releases.statusCalls.value, 3)
    }

    func testAFailureShowsTheProvidersWordsAndARetryRecovers() async {
        let releases = FakeReleases()
        releases.status.value = .failure(.releaseFailed(message: "Not a git checkout."))
        let model = ReleaseModel(provider: Sample.releaseProvider, client: releases)

        await model.refresh()
        XCTAssertEqual(model.state, .failed("Not a git checkout."))
        XCTAssertTrue(model.builds.isEmpty)

        releases.status.value = .success(Sample.releaseStatus)
        await model.refresh()
        XCTAssertEqual(model.selectedApp?.id, "sample")
    }

    func testAProviderWithOnlyStatusIsReadOnly() {
        let readOnly = ReleaseProvider(commands: ReleaseCommands(status: ["./tool"]), folder: URL(fileURLWithPath: "/projects"))
        XCTAssertFalse(ReleaseModel(provider: readOnly, client: FakeReleases()).canAct)
    }

    func testOnlyAProjectWithReleaseCommandsGetsAReleaseMode() async {
        let store = TestStore()
        defer { store.remove() }
        let reader = FakeReader()
        let environment = AppEnvironment(
            reader: reader, discovery: FakeDiscovery(), builder: FakeBuilder(), isXcodeOpen: { false }, releases: FakeReleases()
        )
        let app = AppModel(environment: environment, store: store.make())

        await app.open(Sample.projectURL)
        XCTAssertNil(app.release)
        XCTAssertEqual(app.mode, .build)

        let container = ProjectContainer.sample
        reader.quick.value = .success(Sample.snapshot(
            of: container, config: ProjectConfig(release: Sample.releaseProvider.commands), configFolder: Sample.releaseProvider.folder
        ))
        await app.open(Sample.projectURL)
        XCTAssertEqual(app.release?.provider, Sample.releaseProvider)

        app.mode = .release
        app.closeProject()
        XCTAssertNil(app.release)
        XCTAssertEqual(app.mode, .build)
    }
}

private extension ProjectContainer {
    static var sample: ProjectContainer {
        // The sample path always has a project extension, so this cannot fail.
        (try? ProjectContainer(url: Sample.projectURL)) ?? { fatalError("sample project path") }()
    }
}

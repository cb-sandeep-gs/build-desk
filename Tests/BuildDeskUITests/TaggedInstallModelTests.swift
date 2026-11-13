import BuildDeskCore
@testable import BuildDeskUI
import XCTest

/// A copy of the sample project's code in a made-up folder.
struct FakeTaggedSources: TaggedSourcePreparing {
    static let copyURL = URL(fileURLWithPath: "/copies/Sample-1234/Sample.xcodeproj")
    let prepared = Locked<[String]>([])
    let failure = Locked<BuildDeskError?>(nil)
    let exists = Locked(false)
    let removed = Locked(0)

    private func source(commit: String) throws -> TaggedSource {
        TaggedSource(
            container: try ProjectContainer(url: Self.copyURL), folder: Self.copyURL.deletingLastPathComponent(), commit: commit,
            bytes: 100_000_000
        )
    }

    func prepare(commit: String, of container: ProjectContainer) async throws -> TaggedSource {
        prepared.value += [commit]
        if let failure = failure.value { throw failure }
        exists.value = true
        return try source(commit: commit)
    }

    func existing(for container: ProjectContainer) async -> TaggedSource? {
        exists.value ? try? source(commit: "a41c9e2") : nil
    }

    func remove(_ source: TaggedSource) async throws {
        removed.value += 1
        exists.value = false
    }
}

@MainActor
final class TaggedInstallModelTests: XCTestCase {
    private let store = TestStore()
    private let builder = FakeBuilder()
    private let sources = FakeTaggedSources()
    private let folders = FakeBuildFolders()
    private let releases = FakeReleases()
    private var isXcodeOpen = false

    override func tearDown() {
        store.remove()
        super.tearDown()
    }

    /// An app with the sample project open, a ready device selected and the release status read.
    private func makeApp() async -> AppModel {
        let environment = AppEnvironment(
            reader: FakeReader(), discovery: FakeDiscovery(), builder: builder, isXcodeOpen: { [unowned self] in self.isXcodeOpen },
            buildFolders: folders, releases: releases, taggedSources: sources
        )
        let app = AppModel(environment: environment, store: store.make())
        await app.open(Sample.projectURL)
        await app.refreshEnvironment()
        app.devices.selectedDeviceID = Sample.phone.id
        app.release = ReleaseModel(provider: Sample.releaseProvider, client: releases)
        await app.release?.refresh()
        return app
    }

    func testTheBuildIsMadeFromTheCopyAtItsCommitAndRecordedUnderTheProject() async throws {
        let app = await makeApp()
        app.project?.selectedSchemeName = "Sample"
        XCTAssertNil(app.taggedInstallBlocker(for: Sample.internalBuild))
        builder.events.value = Sample.successfulRun

        await app.installTagged(Sample.internalBuild)

        XCTAssertEqual(sources.prepared.value, [try XCTUnwrap(Sample.internalBuild.commit)])
        let request = try XCTUnwrap(builder.requests.value.first)
        // Built from the copy, never from the checkout.
        XCTAssertEqual(request.container.url, FakeTaggedSources.copyURL)
        XCTAssertEqual(request.scheme, "Sample")
        XCTAssertEqual(request.device, Sample.phone)
        XCTAssertTrue(request.installs)
        XCTAssertEqual(app.taggedInstall?.phase, .running)
        XCTAssertTrue(app.showsTaggedInstall)
        // Build mode says what is on the device now: the build's name stands where a branch would.
        let record = app.installRecords[InstallRecord.key(project: Sample.projectURL, scheme: "Sample", deviceID: Sample.phone.id)]
        XCTAssertEqual(record?.source, SourceState(branch: "SampleInternal-4.2.3", commit: "a41c9e2", hasLocalChanges: false))
        // Its size is known afterwards, so it can be removed.
        XCTAssertNotNil(app.taggedSource)
    }

    func testTheSchemeTheProjectNamesForTheAppWinsOverTheSelection() async {
        let app = await makeApp()
        app.project?.selectedSchemeName = "SampleWatch"
        XCTAssertEqual(app.taggedScheme(for: Sample.internalBuild)?.name, "SampleWatch")

        releases.status.value = .success(ReleaseStatus(
            head: nil,
            apps: [ReleaseApp(id: "sample", name: "Sample", version: "4.2", tracks: [], scheme: "Sample")],
            builds: [Sample.internalBuild]
        ))
        await app.release?.refresh()
        XCTAssertEqual(app.taggedScheme(for: Sample.internalBuild)?.name, "Sample")

        // A scheme without an app can't be installed.
        app.project?.selectedSchemeName = "SampleKit"
        let other = ReleaseBuild(id: "ProInternal-2.0.1", app: "pro", track: "internal", kind: .testflight, version: "2.0.1",
                                 commit: "9f0c1d2")
        XCTAssertNil(app.taggedScheme(for: other))
        XCTAssertEqual(app.taggedInstallBlocker(for: other), "Choose the app's scheme in Build mode first.")
    }

    func testReasonsItCannotBeDone() async {
        let app = await makeApp()
        app.project?.selectedSchemeName = "Sample"

        let noCommit = ReleaseBuild(id: "X-1", app: "sample", track: "internal", kind: .testflight, version: "1")
        XCTAssertEqual(app.taggedInstallBlocker(for: noCommit), "The project does not say which commit this build was made from.")

        app.devices.selectedDeviceID = Sample.offlinePhone.id
        XCTAssertNotNil(app.taggedInstallBlocker(for: Sample.internalBuild))
        await app.installTagged(Sample.internalBuild)
        XCTAssertEqual(sources.prepared.value, [])
        XCTAssertNil(app.taggedInstall)
    }

    func testACopyThatCannotBeMadeShowsWhyAndBuildsNothing() async {
        let app = await makeApp()
        app.project?.selectedSchemeName = "Sample"
        sources.failure.value = .taggedSourceFailed(message: "This Mac doesn't have commit a41c9e2 yet.")

        await app.installTagged(Sample.internalBuild)

        XCTAssertEqual(app.taggedInstall?.phase, .failed("This Mac doesn't have commit a41c9e2 yet."))
        XCTAssertEqual(builder.requests.value, [])
        app.dismissTaggedInstall()
        XCTAssertNil(app.taggedInstall)
    }

    func testALaterRunOfTheCheckoutHidesTheTaggedInstall() async {
        let app = await makeApp()
        app.project?.selectedSchemeName = "Sample"
        await app.installTagged(Sample.internalBuild)
        XCTAssertTrue(app.showsTaggedInstall)

        app.runSelected(.buildOnly)
        await app.run.waitUntilFinished()

        XCTAssertFalse(app.showsTaggedInstall)
    }

    func testRemovingTheCopyAlsoRemovesItsWholeBuildFolder() async {
        let app = await makeApp()
        app.project?.selectedSchemeName = "Sample"
        await app.installTagged(Sample.internalBuild)
        // The copy, its build output and its package checkouts.
        XCTAssertEqual(app.taggedBytes, 100_000_000 + 9_000_000_000)

        // Xcode holds build folders open: nothing is deleted while it runs.
        isXcodeOpen = true
        await app.removeTaggedSource()
        XCTAssertEqual(sources.removed.value, 0)
        XCTAssertEqual(app.taggedSourceMessage, "Xcode is open. Quit it first, then remove the files.")

        isXcodeOpen = false
        await app.removeTaggedSource()
        XCTAssertEqual(sources.removed.value, 1)
        // Not only the Build subfolder: the packages of a copy that is gone would be left behind.
        XCTAssertEqual(folders.removedAll.value, 1)
        XCTAssertEqual(folders.cleaned.value, 0)
        XCTAssertEqual(app.taggedSourceMessage, "9.1 GB freed.")
        XCTAssertNil(app.taggedSource)
        XCTAssertNil(app.taggedBytes)
    }
}

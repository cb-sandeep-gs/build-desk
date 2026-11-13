import BuildDeskCore
@testable import BuildDeskUI
import XCTest

@MainActor
final class ReleaseExtrasModelTests: XCTestCase {
    private let releases = FakeReleases()
    private let full = ReleaseProvider(
        commands: ReleaseCommands(
            status: ["./tool", "status"], plan: ["./tool", "plan"], run: ["./tool", "run"], checks: ["./tool", "checks"],
            store: ["./tool", "store"], artifact: ["./tool", "artifact"]
        ),
        folder: URL(fileURLWithPath: "/projects")
    )

    /// A release whose status offers both build actions and whose store knows the sample build.
    private func makeRelease(provider: ReleaseProvider? = nil) async -> ReleaseModel {
        let status = Sample.releaseStatus
        releases.status.value = .success(ReleaseStatus(
            head: status.head, apps: status.apps, builds: status.builds, branches: status.branches, buildActions: ["notes", "testers"]
        ))
        let model = ReleaseModel(provider: provider ?? full, client: releases, downloadsFolder: URL(fileURLWithPath: "/downloads"))
        await model.refresh()
        return model
    }

    func testABuildsFileIsSavedToTheDownloadsFolder() async {
        let release = await makeRelease()
        XCTAssertTrue(release.canDownload(Sample.internalBuild))
        // The store does not list this build, so there is no cloud build to take a file from.
        XCTAssertFalse(release.canDownload(Sample.storeBuild))

        await release.downloadArtifact(of: Sample.internalBuild)

        XCTAssertEqual(releases.downloads.value, ["SampleInternal-4.2.3 → /downloads"])
        XCTAssertEqual(release.download(of: Sample.internalBuild)?.phase, .done(URL(fileURLWithPath: "/downloads/Sample.ipa")))
        XCTAssertNil(release.download(of: Sample.storeBuild))
    }

    func testAFailedDownloadShowsTheProvidersWordsAndCanBeTriedAgain() async {
        let release = await makeRelease()
        releases.artifactResult.value = .failure(.releaseFailed(message: "Build 812 has no ad-hoc export."))

        await release.downloadArtifact(of: Sample.internalBuild)
        XCTAssertEqual(release.download(of: Sample.internalBuild)?.phase, .failed("Build 812 has no ad-hoc export."))

        releases.artifactResult.value = .success(ReleaseArtifact(file: "/downloads/Sample.ipa"))
        await release.downloadArtifact(of: Sample.internalBuild)
        XCTAssertEqual(releases.downloads.value.count, 2)
    }

    func testNotesNeedTextThenAPlanThenAConfirmation() async throws {
        let release = await makeRelease()
        XCTAssertTrue(release.offers(.notes, for: Sample.internalBuild))

        release.begin(.notes, for: Sample.internalBuild)
        let action = try XCTUnwrap(release.activeAction)
        XCTAssertEqual(action.title, "What to test in 4.2.3")
        XCTAssertEqual(action.problem, "Write what testers should look at in this build.")
        await action.preview()
        XCTAssertEqual(releases.planned.value, [])

        action.action.notes = "Faster search"
        await action.preview()
        XCTAssertEqual(releases.planned.value.first?.build, "SampleInternal-4.2.3")
        XCTAssertEqual(releases.planned.value.first?.kind, .notes)
        XCTAssertEqual(action.confirmTitle(for: try XCTUnwrap(action.plan.value)), "Save Notes")
        // Nothing was written yet.
        XCTAssertEqual(releases.ran.value, [])

        await action.confirm()
        XCTAssertEqual(releases.ran.value.count, 1)
    }

    func testAddingToTestersShowsItsPlanAtOnceAndWritesOnlyOnConfirm() async throws {
        let release = await makeRelease()

        release.begin(.testers, for: Sample.internalBuild)
        let action = try XCTUnwrap(release.activeAction)
        await waitUntil { action.plan.value != nil }

        XCTAssertNil(action.problem)
        XCTAssertEqual(releases.planned.value.map(\.kind), [.testers])
        XCTAssertEqual(releases.ran.value, [])
        XCTAssertEqual(action.confirmTitle(for: try XCTUnwrap(action.plan.value)), "Add to Testers")
    }

    func testBuildActionsAreOfferedOnlyWhereTheyCanWork() async {
        let release = await makeRelease()
        // A store build is not a test build, and the store does not know the other app's build.
        XCTAssertFalse(release.offers(.notes, for: Sample.storeBuild))
        XCTAssertFalse(release.offers(.testers, for: Sample.otherAppBuild))
        // Tagging actions are not build actions.
        XCTAssertFalse(release.offers(.store, for: Sample.internalBuild))

        // A project that can only read offers nothing to do.
        let readOnly = ReleaseProvider(
            commands: ReleaseCommands(status: ["./tool", "status"], store: ["./tool", "store"]), folder: URL(fileURLWithPath: "/projects")
        )
        let quiet = await makeRelease(provider: readOnly)
        XCTAssertFalse(quiet.offers(.notes, for: Sample.internalBuild))
        XCTAssertFalse(quiet.canDownload(Sample.internalBuild))
        XCTAssertFalse(quiet.hasChecks)
    }

    func testChecksAreRunOnRequestAndAFailureIsShown() async {
        let release = await makeRelease()
        XCTAssertTrue(release.hasChecks)
        XCTAssertEqual(release.checks, .idle)

        await release.runChecks()
        XCTAssertEqual(release.checks.value?.isGo, true)

        releases.checksResult.value = .failure(.releaseFailed(message: "No network."))
        await release.runChecks()
        XCTAssertEqual(release.checks, .failed("No network."))
    }
}

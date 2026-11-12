import BuildDeskCore
@testable import BuildDeskUI
import XCTest

@MainActor
final class ReleaseActionModelTests: XCTestCase {
    private func makeRelease(_ releases: FakeReleases) async -> ReleaseModel {
        let model = ReleaseModel(provider: Sample.releaseProvider, client: releases)
        await model.refresh()
        return model
    }

    func testATestBuildStartsOnTheFirstTrackAndThisCheckout() async throws {
        let release = await makeRelease(FakeReleases())
        release.begin(.testflight)
        let action = try XCTUnwrap(release.activeAction)

        XCTAssertEqual(action.title, "New test build of Sample")
        XCTAssertEqual(action.action, ReleaseAction(kind: .testflight, app: "sample", track: "internal"))
        XCTAssertEqual(action.branches, ["develop", "main"])
        XCTAssertEqual(action.checkoutBranch, "develop")
        XCTAssertFalse(action.needsWrittenNotes)
        XCTAssertNil(action.problem)
        XCTAssertFalse(action.canConfirm)

        // A second action cannot start over the first.
        release.begin(.store)
        XCTAssertTrue(release.activeAction === action)
    }

    func testAStoreReleaseStartsOnTheNewestTestBuildOfTheApp() async throws {
        let release = await makeRelease(FakeReleases())
        release.begin(.store)
        let action = try XCTUnwrap(release.activeAction)

        XCTAssertEqual(action.action, ReleaseAction(kind: .store, app: "sample", from: "SampleInternal-4.2.3"))
        // Only this app's test builds can have been shipped.
        XCTAssertEqual(action.shippedCandidates.map(\.id), ["SampleInternal-4.2.3"])
        action.action.from = nil
        XCTAssertEqual(action.problem, "Choose the test build that was shipped.")
    }

    func testATrackWithWrittenNotesNeedsThemBeforeAPreview() async throws {
        let releases = FakeReleases()
        let release = await makeRelease(releases)
        release.begin(.testflight)
        let action = try XCTUnwrap(release.activeAction)

        action.action.track = "partner"
        XCTAssertTrue(action.needsWrittenNotes)
        XCTAssertEqual(action.problem, "Write the notes for this build; this track's notes are not generated.")
        await action.preview()
        XCTAssertTrue(releases.planned.value.isEmpty)

        action.action.notes = "  \n"
        XCTAssertNotNil(action.problem)
        action.action.notes = "Build for payment partners"
        XCTAssertNil(action.problem)
        await action.preview()
        XCTAssertEqual(releases.planned.value.first?.notes, "Build for payment partners")
    }

    func testAPreviewShowsThePlanAndAnyChangeThrowsItAway() async throws {
        let releases = FakeReleases()
        let release = await makeRelease(releases)
        release.begin(.testflight)
        let action = try XCTUnwrap(release.activeAction)

        await action.preview()
        XCTAssertEqual(action.plan, .loaded(Sample.releasePlan))
        XCTAssertTrue(action.canConfirm)

        // The plan was made for the checkout; choosing a branch makes it a different action.
        action.action.branch = "main"
        XCTAssertEqual(action.plan, .idle)
        XCTAssertFalse(action.canConfirm)
        await action.confirm()
        XCTAssertTrue(releases.ran.value.isEmpty)
    }

    func testConfirmRunsThePlanOnScreenThenTheStatusIsReadAgain() async throws {
        let releases = FakeReleases()
        let release = await makeRelease(releases)
        release.begin(.testflight)
        let action = try XCTUnwrap(release.activeAction)
        await action.preview()

        await action.confirm()

        XCTAssertEqual(releases.ran.value, ["testflight SampleInternal-4.2.4, confirming a41c9e2"])
        XCTAssertTrue(action.isDone)
        XCTAssertFalse(action.canConfirm)
        // A second click cannot run it again.
        await action.confirm()
        XCTAssertEqual(releases.ran.value.count, 1)

        let statusReads = releases.statusCalls.value
        await release.endAction()
        XCTAssertNil(release.activeAction)
        XCTAssertEqual(releases.statusCalls.value, statusReads + 1)
    }

    func testARefusedRunShowsWhyAndAsksForANewPlan() async throws {
        let releases = FakeReleases()
        releases.result.value = .failure(.releaseFailed(message: "The code moved since the plan was shown. Review the new plan."))
        let release = await makeRelease(releases)
        release.begin(.testflight)
        let action = try XCTUnwrap(release.activeAction)
        await action.preview()

        await action.confirm()

        XCTAssertEqual(action.runState, .failed("The code moved since the plan was shown. Review the new plan."))
        // The old plan is gone, so the only way forward is a new preview.
        XCTAssertEqual(action.plan, .idle)
        XCTAssertFalse(action.canConfirm)

        // Cancelling an action that did not run reads nothing again.
        let statusReads = releases.statusCalls.value
        await release.endAction()
        XCTAssertEqual(releases.statusCalls.value, statusReads)
    }

    func testAFailedPreviewShowsTheProvidersWords() async throws {
        let releases = FakeReleases()
        releases.plan.value = .failure(.releaseFailed(message: "The checkout has changes. Commit or stash them first."))
        let release = await makeRelease(releases)
        release.begin(.testflight)
        let action = try XCTUnwrap(release.activeAction)

        await action.preview()

        XCTAssertEqual(action.plan, .failed("The checkout has changes. Commit or stash them first."))
        XCTAssertFalse(action.canConfirm)
    }

    func testAReadOnlyProjectCannotStartAnAction() async {
        let readOnly = ReleaseProvider(commands: ReleaseCommands(status: ["./tool"]), folder: URL(fileURLWithPath: "/projects"))
        let release = ReleaseModel(provider: readOnly, client: FakeReleases())
        await release.refresh()
        release.begin(.testflight)
        XCTAssertNil(release.activeAction)
    }
}

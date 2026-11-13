import BuildDeskCore
@testable import BuildDeskUI
import XCTest

@MainActor
final class ReleaseStoreModelTests: XCTestCase {
    private let withStore = ReleaseProvider(
        commands: ReleaseCommands(status: ["./tool", "status"], store: ["./tool", "store"]), folder: URL(fileURLWithPath: "/projects")
    )

    func testStoreStateArrivesWithTheStatusAndIsMatchedToBuilds() async {
        let releases = FakeReleases()
        let model = ReleaseModel(provider: withStore, client: releases)
        XCTAssertTrue(model.hasStore)

        await model.refresh()

        XCTAssertEqual(releases.storeCalls.value, 1)
        let live = model.storeBuild(for: Sample.internalBuild)
        XCTAssertEqual(live?.cloudState, .succeeded)
        XCTAssertEqual(live?.testing, "In testing")
        XCTAssertEqual(live?.groups, ["Staff"])
        // A build the store does not list has no live state.
        XCTAssertNil(model.storeBuild(for: Sample.storeBuild))
        XCTAssertEqual(model.storeApp?.storeVersions?.first?.state, "Prepare for submission")
        XCTAssertEqual(model.storeApp?.alerts?.first?.isError, true)
        XCTAssertNil(model.storeNote)

        // The other app has nothing on the store's side.
        model.selectedAppID = "pro"
        XCTAssertNil(model.storeApp)
    }

    func testAProjectWithoutAStoreCommandNeverAsks() async {
        let releases = FakeReleases()
        let model = ReleaseModel(provider: Sample.releaseProvider, client: releases)

        await model.refresh()

        XCTAssertFalse(model.hasStore)
        XCTAssertEqual(releases.storeCalls.value, 0)
        XCTAssertEqual(model.store, .idle)
        XCTAssertNil(model.storeNote)
    }

    func testNotConnectedAndFailuresAreNotesNotErrors() async {
        let releases = FakeReleases()
        releases.storeStatus.value = .success(ReleaseStoreStatus(connected: false, hint: "Run the login command."))
        let model = ReleaseModel(provider: withStore, client: releases)

        await model.refresh()
        // The status itself is fine; only the live part is missing.
        XCTAssertEqual(model.selectedApp?.id, "sample")
        XCTAssertEqual(model.storeNote, "Store not connected. Run the login command.")
        XCTAssertFalse(model.storeFailed)
        XCTAssertNil(model.storeBuild(for: Sample.internalBuild))

        releases.storeStatus.value = .failure(.releaseFailed(message: "The network is down."))
        await model.refresh()
        XCTAssertEqual(model.storeNote, "Couldn't read the store: The network is down.")
        XCTAssertTrue(model.storeFailed)
        XCTAssertNotNil(model.status)
    }

    func testAFailedStatusDoesNotAskTheStore() async {
        let releases = FakeReleases()
        releases.status.value = .failure(.releaseFailed(message: "Not a git checkout."))
        let model = ReleaseModel(provider: withStore, client: releases)

        await model.refresh()

        XCTAssertEqual(releases.storeCalls.value, 0)
    }

    func testAnUnknownCloudWordIsShownAsUnknown() {
        XCTAssertNil(ReleaseStoreBuild(id: "x", cloud: "queued").cloudState)
        XCTAssertEqual(ReleaseStoreBuild(id: "x", cloud: "running").cloudState, .running)
        XCTAssertFalse(ReleaseAlert(severity: "warning", message: "m").isError)
    }
}

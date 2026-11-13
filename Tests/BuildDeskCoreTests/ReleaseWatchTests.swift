@testable import BuildDeskCore
import XCTest

final class ReleaseWatchTests: XCTestCase {
    private func status(_ builds: [ReleaseStoreBuild], connected: Bool = true, app: String = "sample") -> ReleaseStoreStatus {
        ReleaseStoreStatus(connected: connected, apps: connected ? [ReleaseStoreApp(id: app, builds: builds)] : [])
    }

    func testACloudBuildThatEndsIsReportedOnce() {
        let running = status([ReleaseStoreBuild(id: "A-1", cloud: "running")])
        let succeeded = status([ReleaseStoreBuild(id: "A-1", cloud: "succeeded")])
        let failed = status([ReleaseStoreBuild(id: "A-1", cloud: "failed")])

        XCTAssertEqual(
            ReleaseWatch.changes(from: running, to: succeeded), [ReleaseChange(app: "sample", build: "A-1", kind: .cloudSucceeded)]
        )
        XCTAssertEqual(ReleaseWatch.changes(from: running, to: failed), [ReleaseChange(app: "sample", build: "A-1", kind: .cloudFailed)])
        // Nothing moved: nothing to say, however often the store is read.
        XCTAssertEqual(ReleaseWatch.changes(from: running, to: running), [])
        XCTAssertEqual(ReleaseWatch.changes(from: succeeded, to: succeeded), [])
    }

    func testReachingTestersIsReportedAndWinsOverTheCloudResult() {
        let running = status([ReleaseStoreBuild(id: "A-1", cloud: "running")])
        let built = status([ReleaseStoreBuild(id: "A-1", cloud: "succeeded")])
        let testing = status([ReleaseStoreBuild(id: "A-1", cloud: "succeeded", testing: "In testing")])

        XCTAssertEqual(
            ReleaseWatch.changes(from: built, to: testing),
            [ReleaseChange(app: "sample", build: "A-1", kind: .reachedTesters("In testing"))]
        )
        // Both steps between two readings: one notice, the one that says more.
        XCTAssertEqual(ReleaseWatch.changes(from: running, to: testing).map(\.kind), [.reachedTesters("In testing")])
        // A testing state that only changes its words is not a new arrival.
        let expired = status([ReleaseStoreBuild(id: "A-1", cloud: "succeeded", testing: "Expired")])
        XCTAssertEqual(ReleaseWatch.changes(from: testing, to: expired), [])
    }

    func testANewBuildIsOnlyReportedWhenItAlreadyFailed() {
        let before = status([ReleaseStoreBuild(id: "A-1", cloud: "succeeded")])
        let after = status([
            ReleaseStoreBuild(id: "A-3", cloud: "failed"), ReleaseStoreBuild(id: "A-2", cloud: "running"),
            ReleaseStoreBuild(id: "A-1", cloud: "succeeded"),
        ])

        XCTAssertEqual(ReleaseWatch.changes(from: before, to: after), [ReleaseChange(app: "sample", build: "A-3", kind: .cloudFailed)])
    }

    func testAReadingAfterNotConnectedOrOfANewAppReportsNothing() {
        let offline = status([], connected: false)
        let online = status([ReleaseStoreBuild(id: "A-1", cloud: "failed")])
        XCTAssertEqual(ReleaseWatch.changes(from: offline, to: online), [])
        XCTAssertEqual(ReleaseWatch.changes(from: online, to: offline), [])

        let otherApp = status([ReleaseStoreBuild(id: "B-1", cloud: "failed")], app: "pro")
        XCTAssertEqual(ReleaseWatch.changes(from: online, to: otherApp), [])
    }

    func testTheStoreIsReadOftenOnlyWhileACloudBuildIsRunning() {
        let running = status([ReleaseStoreBuild(id: "A-1", cloud: "running")])
        let done = status([ReleaseStoreBuild(id: "A-1", cloud: "succeeded")])

        XCTAssertEqual(ReleaseWatch.interval(after: running), BuildDeskConstants.ReleaseWatch.activeSeconds)
        XCTAssertEqual(ReleaseWatch.interval(after: done), BuildDeskConstants.ReleaseWatch.idleSeconds)
        XCTAssertEqual(ReleaseWatch.interval(after: nil), BuildDeskConstants.ReleaseWatch.idleSeconds)
        XCTAssertEqual(ReleaseWatch.interval(after: status([], connected: false)), BuildDeskConstants.ReleaseWatch.idleSeconds)
        XCTAssertLessThan(BuildDeskConstants.ReleaseWatch.activeSeconds, BuildDeskConstants.ReleaseWatch.idleSeconds)
    }
}

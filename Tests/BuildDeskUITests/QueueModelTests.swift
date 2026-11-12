import BuildDeskCore
@testable import BuildDeskUI
import XCTest

@MainActor
final class QueueModelTests: XCTestCase {
    private func pin(_ scheme: String, device: Device = Sample.phone, configuration: String = "Debug") -> PinnedRun {
        PinnedRun(project: Sample.projectURL, scheme: scheme, configuration: configuration, deviceID: device.id, deviceName: device.name)
    }

    private func makeApp(
        _ store: TestStore, builder: FakeBuilder, notifier: FakeNotifier = FakeNotifier(), isActive: Bool = false
    ) -> AppModel {
        let environment = AppEnvironment(
            reader: FakeReader(), discovery: FakeDiscovery(), builder: builder, isXcodeOpen: { false },
            notifier: notifier, isAppActive: { isActive }
        )
        return AppModel(environment: environment, store: store.make())
    }

    func testPinsRunInOrderAndAFailureDoesNotStopTheRest() async {
        let store = TestStore()
        defer { store.remove() }
        let builder = FakeBuilder()
        builder.events.value = Sample.successfulRun
        builder.failingSchemes.value = ["SampleWidget"]
        let notifier = FakeNotifier()
        let app = makeApp(store, builder: builder, notifier: notifier)
        let pins = [pin("Sample"), pin("SampleWidget"), pin("Sample", device: Sample.offlinePhone), pin("Sample", configuration: "Staging")]

        app.queue.start(pins, mode: .buildAndInstall)
        XCTAssertTrue(app.queue.isRunning)
        XCTAssertEqual(app.queue.state(of: pins[3]), .waiting)
        await app.queue.waitUntilFinished()

        XCTAssertFalse(app.queue.isRunning)
        XCTAssertEqual(app.queue.items.map(\.state), [
            .succeeded,
            .failed("The build failed. Open the full log for details."),
            // This pin never started: its device is not connected.
            .failed("Old iPhone is not connected. Connect it with a cable and unlock it."),
            .succeeded,
        ])
        XCTAssertEqual(builder.requests.value.map(\.scheme), ["Sample", "SampleWidget", "Sample"])
        XCTAssertEqual(builder.requests.value.map(\.configuration), ["Debug", "Debug", "Staging"])
        // One notice for the queue, none per build.
        await waitUntil { !notifier.notices.value.isEmpty }
        XCTAssertEqual(notifier.notices.value, [
            RunNotice(title: "2 of 4 builds failed", body: "2 succeeded. Failed: SampleWidget and Sample."),
        ])
    }

    func testAQueueThatAllSucceedsSaysSo() async {
        let store = TestStore()
        defer { store.remove() }
        let builder = FakeBuilder()
        builder.events.value = Sample.successfulRun
        let app = makeApp(store, builder: builder)

        app.queue.start([pin("Sample"), pin("SampleWidget")], mode: .buildOnly)
        await app.queue.waitUntilFinished()

        XCTAssertEqual(app.queue.notice, RunNotice(title: "All 2 builds finished", body: "Every pinned build succeeded."))
        // Build only: nothing is installed.
        XCTAssertEqual(builder.requests.value.map(\.installs), [false, false])
    }

    func testStoppingSkipsWhatIsLeft() async {
        let store = TestStore()
        defer { store.remove() }
        let builder = FakeBuilder()
        builder.events.value = [.stepStarted(.build)]
        builder.hangs.value = true
        let notifier = FakeNotifier()
        let app = makeApp(store, builder: builder, notifier: notifier)
        let pins = [pin("Sample"), pin("SampleWidget")]

        app.queue.start(pins, mode: .buildAndInstall)
        await waitUntil { app.run.statuses[.build] == .running }
        // A second queue, or a single run, cannot start meanwhile.
        app.queue.start([pin("SampleKit")], mode: .buildOnly)
        XCTAssertEqual(app.queue.items.count, 2)

        app.queue.stop()
        await app.queue.waitUntilFinished()

        XCTAssertEqual(app.queue.items.map(\.state), [.skipped, .skipped])
        XCTAssertNil(app.queue.notice)
        XCTAssertEqual(builder.requests.value.count, 1)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(notifier.notices.value.isEmpty)
    }

    func testAnEmptyQueueDoesNothing() {
        let store = TestStore()
        defer { store.remove() }
        let app = makeApp(store, builder: FakeBuilder())
        app.queue.start([], mode: .buildAndInstall)
        XCTAssertFalse(app.queue.isRunning)
    }
}

@MainActor
final class ScheduleModelTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute)) ?? Date()
    }

    func testNextRunIsTodayIfTheTimeIsAheadElseTomorrow() {
        let nineOClock = 9 * 60
        XCTAssertEqual(ScheduleModel.nextFireDate(after: date(10, 7, 30), minuteOfDay: nineOClock, calendar: calendar), date(10, 9, 0))
        XCTAssertEqual(ScheduleModel.nextFireDate(after: date(10, 9, 30), minuteOfDay: nineOClock, calendar: calendar), date(11, 9, 0))
        // Exactly at the time, the next run is tomorrow, so it never fires twice in a row.
        XCTAssertEqual(ScheduleModel.nextFireDate(after: date(10, 9, 0), minuteOfDay: nineOClock, calendar: calendar), date(11, 9, 0))
        XCTAssertEqual(ScheduleModel.nextFireDate(after: date(10, 9, 0), minuteOfDay: 17 * 60 + 45, calendar: calendar), date(10, 17, 45))
    }

    func testTheScheduleIsOffByDefaultAndItsSettingsAreKept() {
        let store = TestStore()
        defer { store.remove() }
        let schedule = ScheduleModel(store: store.make())
        XCTAssertFalse(schedule.isEnabled)
        XCTAssertEqual(schedule.minuteOfDay, 9 * 60)

        schedule.minuteOfDay = 7 * 60 + 15
        schedule.isEnabled = true
        let reopened = ScheduleModel(store: store.make())
        XCTAssertTrue(reopened.isEnabled)
        XCTAssertEqual(reopened.minuteOfDay, 7 * 60 + 15)
        XCTAssertEqual(Calendar.current.dateComponents([.hour, .minute], from: reopened.time), DateComponents(hour: 7, minute: 15))
        schedule.isEnabled = false
    }

    func testFiringBuildsEveryPinWithoutInstalling() async {
        let store = TestStore()
        defer { store.remove() }
        let builder = FakeBuilder()
        builder.events.value = Sample.successfulRun
        let environment = AppEnvironment(reader: FakeReader(), discovery: FakeDiscovery(), builder: builder, isXcodeOpen: { false })
        let app = AppModel(environment: environment, store: store.make())

        // Nothing pinned: nothing to do.
        app.schedule.fire()
        XCTAssertNil(app.schedule.lastFired)

        await app.open(Sample.projectURL)
        await app.refreshEnvironment()
        app.togglePinForSelection()
        app.schedule.fire()
        await app.queue.waitUntilFinished()

        XCTAssertNotNil(app.schedule.lastFired)
        XCTAssertEqual(builder.requests.value.map(\.installs), [false])
        XCTAssertEqual(app.queue.items.map(\.state), [.succeeded])
    }
}

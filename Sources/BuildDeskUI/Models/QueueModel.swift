import BuildDeskCore
import Foundation
import Observation

/// Several pins run one after another, with one result per pin and one notification at the end.
@MainActor
@Observable
public final class QueueModel {
    public enum State: Equatable, Sendable {
        case waiting
        case running
        case succeeded
        case failed(String)
        /// Not run, because the queue was stopped before its turn.
        case skipped
    }

    public struct Item: Identifiable, Equatable, Sendable {
        public let pin: PinnedRun
        public var state: State

        public var id: String { pin.id }
    }

    public private(set) var items: [Item] = []
    public private(set) var isRunning = false

    /// The app the queue drives. Weak: the app owns the queue.
    weak var app: AppModel?
    private var task: Task<Void, Never>?

    public init() {}

    public func state(of pin: PinnedRun) -> State? {
        items.first { $0.id == pin.id }?.state
    }

    /// Runs the pins in order. A pin that fails does not stop the ones after it: they are
    /// separate builds, and one broken scheme should not cost the others.
    public func start(_ pins: [PinnedRun], mode: RunMode) {
        guard !isRunning, !pins.isEmpty, let app, !app.run.isRunning, !app.tests.isRunning else { return }
        items = pins.map { Item(pin: $0, state: .waiting) }
        isRunning = true
        task = Task { [weak self] in
            await self?.runAll(mode)
        }
    }

    /// Stops the pin that is running and skips the rest.
    public func stop() {
        task?.cancel()
        app?.run.stop()
    }

    /// Lets tests wait for the queue to end.
    public func waitUntilFinished() async {
        await task?.value
    }

    private func runAll(_ mode: RunMode) async {
        for index in items.indices {
            guard let app, !Task.isCancelled else { break }
            items[index].state = .running
            await app.run(items[index].pin, mode: mode)
            if let problem = app.pinError {
                // The pin never started: its device is away, or its scheme is gone.
                items[index].state = .failed(problem)
                continue
            }
            await app.run.waitUntilFinished()
            switch app.run.phase {
            case .succeeded: items[index].state = .succeeded
            case .failed(let message): items[index].state = .failed(message)
            case .stopped, .idle, .running: items[index].state = .skipped
            }
            // A stopped run means the person stopped the queue.
            if app.run.phase == .stopped { break }
        }
        for index in items.indices where items[index].state == .waiting || items[index].state == .running {
            items[index].state = .skipped
        }
        isRunning = false
        await app?.announceQueueFinished()
    }

    /// One notice for the whole queue; nil when it was stopped before anything finished.
    public var notice: RunNotice? {
        let succeeded = items.filter { $0.state == .succeeded }.count
        let failed = items.filter { if case .failed = $0.state { true } else { false } }
        guard succeeded + failed.count > 0 else { return nil }
        let names = failed.map(\.pin.scheme).formatted(.list(type: .and))
        return RunNotice(
            title: failed.isEmpty ? "All \(succeeded) builds finished" : "\(failed.count) of \(items.count) builds failed",
            body: failed.isEmpty ? "Every pinned build succeeded." : "\(succeeded) succeeded. Failed: \(names)."
        )
    }
}

/// Runs the pins once a day at a set time, while Build Desk is open, so the first build of the
/// working day is an incremental one.
@MainActor
@Observable
public final class ScheduleModel {
    public var isEnabled: Bool {
        didSet {
            store.scheduleIsEnabled = isEnabled
            restart()
        }
    }
    /// Minutes after midnight.
    public var minuteOfDay: Int {
        didSet {
            store.scheduleMinuteOfDay = minuteOfDay
            restart()
        }
    }
    /// When the schedule last ran the pins.
    public private(set) var lastFired: Date?

    weak var app: AppModel?
    private let store: PreferenceStore
    private var task: Task<Void, Never>?

    public init(store: PreferenceStore) {
        self.store = store
        isEnabled = store.scheduleIsEnabled
        minuteOfDay = store.scheduleMinuteOfDay
    }

    /// The time of day as a date today, for a time picker.
    public var time: Date {
        get { Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(minuteOfDay * Self.secondsPerMinute)) }
        set {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            minuteOfDay = (parts.hour ?? 0) * Self.minutesPerHour + (parts.minute ?? 0)
        }
    }

    private static let secondsPerMinute = 60
    private static let minutesPerHour = 60

    /// The next moment the clock shows the set time, strictly after `now`.
    public static func nextFireDate(after now: Date, minuteOfDay: Int, calendar: Calendar = .current) -> Date {
        let time = DateComponents(hour: minuteOfDay / minutesPerHour, minute: minuteOfDay % minutesPerHour, second: 0)
        return calendar.nextDate(after: now, matching: time, matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(TimeInterval(24 * minutesPerHour * secondsPerMinute))
    }

    /// Starts waiting for the next run. Called once when the app starts, and again on every change.
    public func restart() {
        task?.cancel()
        task = nil
        guard isEnabled else { return }
        let minuteOfDay = minuteOfDay
        task = Task { [weak self] in
            while !Task.isCancelled {
                let wait = Self.nextFireDate(after: Date(), minuteOfDay: minuteOfDay).timeIntervalSinceNow
                try? await Task.sleep(for: .seconds(max(wait, 1)))
                guard !Task.isCancelled else { return }
                self?.fire()
            }
        }
    }

    /// Builds every pin, without installing: a device may not be connected at that hour, and the
    /// point is a warm build folder. Skipped when something is already running.
    public func fire() {
        guard let app, !app.pins.isEmpty, !app.queue.isRunning, !app.run.isRunning, !app.tests.isRunning else { return }
        lastFired = Date()
        app.queue.start(app.pins, mode: .buildOnly)
    }
}

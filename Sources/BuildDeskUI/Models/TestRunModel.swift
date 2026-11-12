import BuildDeskCore
import Foundation
import Observation

/// Where a test run stands.
public enum TestPhase: Equatable, Sendable {
    case idle
    /// Building what the tests need.
    case building
    /// Tests are running.
    case testing
    /// Tests ran; `summary` says how they went.
    case finished
    /// The run did not get as far as results (the build broke, or the tool failed).
    case failed(String)
    /// Stopped by the user.
    case stopped
}

/// The tests of one class or suite, as one section of the results.
public struct TestSuiteResults: Identifiable, Equatable, Sendable {
    public let bundle: String
    public let suite: String
    public let cases: [TestCaseResult]

    public var id: String { "\(bundle)/\(suite)" }
    public var failedCount: Int { cases.filter { $0.status == .failed }.count }
}

/// One test run, from the click on Run Tests to its results.
@MainActor
@Observable
public final class TestRunModel {
    public private(set) var phase: TestPhase = .idle
    public private(set) var request: TestRequest?
    /// Tests finished so far, counted from the run's live output.
    public private(set) var liveCounts: [TestCaseResult.Status: Int] = [:]
    /// The test that finished last, shown while the run is going.
    public private(set) var latestTest: String?
    public private(set) var buildTaskCount = 0
    /// Build errors, when the run failed before any test ran.
    public private(set) var errors: [Diagnostic] = []
    public private(set) var summary: TestRunSummary?
    public private(set) var logFile: URL?
    public private(set) var startedAt: Date?
    public private(set) var finishedAt: Date?

    private let tester: any TestRunning
    private var task: Task<Void, Never>?

    public init(tester: any TestRunning) {
        self.tester = tester
    }

    public var isRunning: Bool { phase == .building || phase == .testing }

    /// How many tests have finished so far in the running run.
    public var liveTotal: Int { liveCounts.values.reduce(0, +) }

    /// The results by class, classes with failures first, then by name.
    public var suites: [TestSuiteResults] {
        let grouped = Dictionary(grouping: summary?.cases ?? []) { "\($0.bundle)/\($0.suite)" }
        return grouped.values
            .compactMap { cases in cases.first.map { TestSuiteResults(bundle: $0.bundle, suite: $0.suite, cases: cases) } }
            .sorted { lhs, rhs in
                if (lhs.failedCount > 0) != (rhs.failedCount > 0) { return lhs.failedCount > 0 }
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }
    }

    public func start(_ request: TestRequest) {
        guard !isRunning else { return }
        self.request = request
        liveCounts = [:]
        latestTest = nil
        buildTaskCount = 0
        errors = []
        summary = nil
        logFile = nil
        startedAt = Date()
        finishedAt = nil
        phase = .building
        let events = tester.run(request)
        task = Task { [weak self] in
            await self?.consume(events)
        }
    }

    /// Stops the run; the runner stops `xcodebuild`, so nothing keeps testing.
    public func stop() {
        task?.cancel()
    }

    /// Lets tests wait for the run to end.
    public func waitUntilFinished() async {
        await task?.value
    }

    private func consume(_ events: AsyncThrowingStream<TestEvent, Error>) async {
        do {
            for try await event in events { apply(event) }
            // A stream that ends without results was cut short by a stop.
            if summary == nil { finish(.stopped) }
        } catch is CancellationError {
            finish(.stopped)
        } catch {
            if case BuildDeskError.buildFailed(let found, let path) = error {
                errors = found
                logFile = path.map { URL(fileURLWithPath: $0) }
            }
            finish(Task.isCancelled ? .stopped : .failed(userMessage(for: error)))
        }
    }

    private func apply(_ event: TestEvent) {
        switch event {
        case .build(.task):
            buildTaskCount += 1
        case .build:
            break
        case .testingStarted:
            phase = .testing
        case .caseFinished(let suite, let name, let status):
            liveCounts[status, default: 0] += 1
            latestTest = "\(suite).\(name)"
        case .finished(let summary):
            self.summary = summary
            logFile = summary.logFile
            finish(.finished)
        }
    }

    private func finish(_ result: TestPhase) {
        finishedAt = Date()
        phase = result
    }
}

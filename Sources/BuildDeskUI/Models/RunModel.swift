import BuildDeskCore
import Foundation
import Observation

/// Where a run stands as a whole.
public enum RunPhase: Equatable, Sendable {
    case idle
    case running
    case succeeded
    case failed(String)
    /// Stopped by the user.
    case stopped
}

/// Where one step of a run stands.
public enum StepStatus: Equatable, Sendable {
    case pending
    case running
    case done(seconds: Double)
    case failed
}

/// One run, from the click on Build to its result, in the shape the window draws.
@MainActor
@Observable
public final class RunModel {
    /// Diagnostics kept for display. A broken build can print thousands; the full list is in the log.
    public static let diagnosticLimit = 500

    public private(set) var phase: RunPhase = .idle
    public private(set) var request: BuildRequest?
    /// The steps this run goes through; a build-only run has one.
    public private(set) var steps: [PipelineStep] = []
    public private(set) var statuses: [PipelineStep: StepStatus] = [:]
    public private(set) var taskCount = 0
    /// The target being built right now.
    public private(set) var currentTarget: String?
    public private(set) var isResolvingPackages = false
    public private(set) var errors: [Diagnostic] = []
    public private(set) var warnings: [Diagnostic] = []
    public private(set) var summary: RunSummary?
    public private(set) var logFile: URL?
    public private(set) var startedAt: Date?
    public private(set) var finishedAt: Date?
    /// Build tasks the last good build of the same scheme ran; nil the first time.
    public private(set) var expectedTaskCount: Int?

    private let builder: any BuildRunning
    private var task: Task<Void, Never>?
    private var seenDiagnostics = Set<Diagnostic>()

    public init(builder: any BuildRunning) {
        self.builder = builder
    }

    public var isRunning: Bool { phase == .running }

    /// How far the build step is, from 0 to 1, when a previous build gives something to measure
    /// against. Held just short of 1 until the build really ends: this build may have more tasks.
    public var buildProgress: Double? {
        guard let expectedTaskCount, expectedTaskCount > 0 else { return nil }
        return min(Double(taskCount) / Double(expectedTaskCount), Self.progressCeiling)
    }

    private static let progressCeiling = 0.98

    public func start(_ request: BuildRequest, expectedTaskCount: Int? = nil) {
        guard !isRunning else { return }
        reset(for: request, expectedTaskCount: expectedTaskCount)
        let events = builder.run(request)
        task = Task { [weak self] in
            await self?.consume(events)
        }
    }

    /// Stops the run. The pipeline stops the tool it is running, so nothing keeps building.
    public func stop() {
        task?.cancel()
    }

    /// Lets tests wait for the run to end.
    public func waitUntilFinished() async {
        await task?.value
    }

    private func reset(for request: BuildRequest, expectedTaskCount: Int?) {
        self.request = request
        self.expectedTaskCount = expectedTaskCount
        steps = PipelineStep.allCases.filter { step in
            switch step {
            case .build: request.builds
            case .locate, .install: request.installs
            case .launch: request.installs && request.launches
            }
        }
        statuses = Dictionary(uniqueKeysWithValues: steps.map { ($0, StepStatus.pending) })
        taskCount = 0
        currentTarget = nil
        isResolvingPackages = false
        errors = []
        warnings = []
        seenDiagnostics = []
        summary = nil
        logFile = nil
        startedAt = Date()
        finishedAt = nil
        phase = .running
    }

    private func consume(_ events: AsyncThrowingStream<PipelineEvent, Error>) async {
        do {
            for try await event in events { apply(event) }
            // A stream that ends without a summary was cut short by a stop.
            if summary == nil { finish(.stopped) }
        } catch is CancellationError {
            finish(.stopped)
        } catch {
            if case BuildDeskError.buildFailed(_, let path?) = error { logFile = URL(fileURLWithPath: path) }
            finish(Task.isCancelled ? .stopped : .failed(userMessage(for: error)))
        }
    }

    private func apply(_ event: PipelineEvent) {
        switch event {
        case .stepStarted(let step):
            statuses[step] = .running
        case .stepFinished(let step, let seconds):
            statuses[step] = .done(seconds: seconds)
            if step == .build { currentTarget = nil }
        case .build(.resolvingPackages):
            isResolvingPackages = true
        case .build(.task(_, let target)):
            isResolvingPackages = false
            taskCount += 1
            if currentTarget != target { currentTarget = target }
        case .build(.diagnostic(let diagnostic)):
            record(diagnostic)
        case .build(.outcome):
            break
        case .finished(let summary):
            self.summary = summary
            logFile = summary.logFile
            finish(.succeeded)
        }
    }

    private func record(_ diagnostic: Diagnostic) {
        guard seenDiagnostics.insert(diagnostic).inserted else { return }
        switch diagnostic.severity {
        case .error where errors.count < Self.diagnosticLimit: errors.append(diagnostic)
        case .warning where warnings.count < Self.diagnosticLimit: warnings.append(diagnostic)
        default: break
        }
    }

    private func finish(_ result: RunPhase) {
        // Whatever was in progress when the run ended did not complete.
        for (step, status) in statuses where status == .running {
            statuses[step] = result == .succeeded ? .done(seconds: 0) : .failed
        }
        finishedAt = Date()
        phase = result
    }
}

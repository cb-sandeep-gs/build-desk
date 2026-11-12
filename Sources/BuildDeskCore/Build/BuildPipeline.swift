import Foundation

/// One run from start to finish: build the scheme, find the app it produced, install it on the
/// device and launch it. Progress is reported as events, so the command line and the app show the
/// same run the same way.
public struct BuildPipeline: Sendable {
    private typealias Emit = @Sendable (PipelineEvent) -> Void

    private let toolRunner: any ToolRunning
    private let logDirectory: URL?

    /// - Parameter logDirectory: where full build logs go; nil turns logging off.
    public init(toolRunner: any ToolRunning = ProcessToolRunner(), logDirectory: URL? = RunLog.defaultDirectory) {
        self.toolRunner = toolRunner
        self.logDirectory = logDirectory
    }

    /// Starts the run. Stopping the iteration, or cancelling the task that iterates, stops the
    /// build and leaves no tool running.
    public func run(_ request: BuildRequest) -> AsyncThrowingStream<PipelineEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let summary = try await execute(request) { continuation.yield($0) }
                    continuation.yield(.finished(summary))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Steps

    private func execute(_ request: BuildRequest, emit: Emit) async throws -> RunSummary {
        // A log that cannot be created must not block the build.
        let log = logDirectory.flatMap { try? RunLog(directory: $0, scheme: request.scheme) }
        var seconds: [PipelineStep: Double] = [:]

        let report: BuildReport
        do {
            report = try await step(.build, &seconds, emit) { try await build(request, log: log, emit: emit) }
        } catch {
            await log?.close()
            throw error
        }
        await log?.close()

        var product: BuiltProduct?
        if request.installs {
            let built = try await step(.locate, &seconds, emit) { try await locateProduct(request) }
            product = built
            try await step(.install, &seconds, emit) { try await install(built, on: request.device) }
            if request.launches {
                try await step(.launch, &seconds, emit) { try await launch(built, on: request.device) }
            }
        }
        return RunSummary(
            product: product,
            taskCount: report.taskCount,
            warnings: report.warnings,
            secondsByStep: seconds,
            logFile: log?.url
        )
    }

    /// Runs one step, reporting its start, its end and how long it took.
    private func step<T: Sendable>(
        _ step: PipelineStep,
        _ seconds: inout [PipelineStep: Double],
        _ emit: Emit,
        _ work: () async throws -> T
    ) async throws -> T {
        emit(.stepStarted(step))
        let started = ContinuousClock.now
        let value = try await work()
        let elapsed = started.duration(to: .now).components
        let duration = Double(elapsed.seconds) + Double(elapsed.attoseconds) / Self.attosecondsPerSecond
        seconds[step] = duration
        emit(.stepFinished(step, seconds: duration))
        return value
    }

    private static let attosecondsPerSecond = 1e18

    private func build(_ request: BuildRequest, log: RunLog?, emit: Emit) async throws -> BuildReport {
        let parser = BuildOutputParser()
        var report = BuildReport()
        var exitCode: Int32 = 0

        for try await output in toolRunner.stream(AppleTools.build(request)) {
            switch output {
            case .line(let line):
                await log?.append(line)
                guard let event = parser.parse(line) else { continue }
                report.record(event)
                emit(.build(event))
            case .exit(let code):
                exitCode = code
            }
        }
        // A cancelled run ends the output early; report it as cancelled, not as a failed build.
        try Task.checkCancellation()
        guard exitCode == 0 else {
            throw BuildDeskError.buildFailed(errors: report.errors, logFile: log?.url.path)
        }
        return report
    }

    private func locateProduct(_ request: BuildRequest) async throws -> BuiltProduct {
        let command = AppleTools.buildSettings(request)
        let result = try await toolRunner.run(command)
        guard result.succeeded else {
            throw BuildDeskError.stepFailed(step: .locate, message: result.failureTail())
        }
        return try BuildSettingsParser.product(in: result.stdout, scheme: request.scheme)
    }

    private func install(_ product: BuiltProduct, on device: Device) async throws {
        switch device.kind {
        case .physical:
            try await runChecked(AppleTools.installOnDevice(udid: device.id, app: product.appURL), step: .install)
        case .simulator:
            // An install on a simulator that is not running fails, so make sure it is booted first.
            try await runChecked(AppleTools.bootSimulator(udid: device.id), step: .install)
            try await runChecked(AppleTools.installOnSimulator(udid: device.id, app: product.appURL), step: .install)
        }
    }

    private func launch(_ product: BuiltProduct, on device: Device) async throws {
        let command = switch device.kind {
        case .physical: AppleTools.launchOnDevice(udid: device.id, bundleIdentifier: product.bundleIdentifier)
        case .simulator: AppleTools.launchOnSimulator(udid: device.id, bundleIdentifier: product.bundleIdentifier)
        }
        try await runChecked(command, step: .launch)
    }

    private func runChecked(_ command: ToolCommand, step: PipelineStep) async throws {
        let result = try await toolRunner.run(command)
        guard result.succeeded else {
            throw BuildDeskError.stepFailed(step: step, message: result.failureTail())
        }
    }
}

/// What the build output added up to.
private struct BuildReport: Sendable {
    private(set) var taskCount = 0
    private(set) var errors: [Diagnostic] = []
    private(set) var warnings: [Diagnostic] = []
    /// xcodebuild prints a diagnostic again each time another file includes the one it is in.
    private var seen = Set<Diagnostic>()

    mutating func record(_ event: BuildEvent) {
        switch event {
        case .task:
            taskCount += 1
        case .diagnostic(let diagnostic):
            guard seen.insert(diagnostic).inserted else { return }
            switch diagnostic.severity {
            case .error: errors.append(diagnostic)
            case .warning: warnings.append(diagnostic)
            case .note: break
            }
        case .resolvingPackages, .outcome:
            break
        }
    }
}

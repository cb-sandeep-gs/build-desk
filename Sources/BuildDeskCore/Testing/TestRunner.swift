import Foundation

/// Runs a scheme's tests and reports each test's result.
public protocol TestRunning: Sendable {
    func run(_ request: TestRequest) -> AsyncThrowingStream<TestEvent, Error>
}

/// Runs tests with `xcodebuild test` and reads the results from the result bundle it writes.
public struct TestRunner: TestRunning {
    private static let resultsFolder = "BuildDeskTestResults"
    private static let bundleExtension = "xcresult"
    private static let attosecondsPerSecond = 1e18

    private let toolRunner: any ToolRunning
    private let logDirectory: URL?
    private let resultsDirectory: URL

    /// - Parameters:
    ///   - logDirectory: where full output goes; nil turns logging off.
    ///   - resultsDirectory: where result bundles are written before they are read and deleted;
    ///     nil uses a folder in the system's temporary directory.
    public init(
        toolRunner: any ToolRunning = ProcessToolRunner(),
        logDirectory: URL? = RunLog.defaultDirectory,
        resultsDirectory: URL? = nil
    ) {
        self.toolRunner = toolRunner
        self.logDirectory = logDirectory
        self.resultsDirectory = resultsDirectory
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(Self.resultsFolder)
    }

    public func run(_ request: TestRequest) -> AsyncThrowingStream<TestEvent, Error> {
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

    private func execute(_ request: TestRequest, emit: @Sendable (TestEvent) -> Void) async throws -> TestRunSummary {
        try? FileManager.default.createDirectory(at: resultsDirectory, withIntermediateDirectories: true)
        let bundle = resultsDirectory.appendingPathComponent("\(UUID().uuidString).\(Self.bundleExtension)")
        // A result bundle can be hundreds of megabytes; it is read once and never kept.
        defer { try? FileManager.default.removeItem(at: bundle) }
        let log = logDirectory.flatMap { try? RunLog(directory: $0, scheme: "\(request.scheme)-tests") }
        let started = ContinuousClock.now

        let (exitCode, errors) = try await runTests(request, bundle: bundle, log: log, emit: emit)
        await log?.close()
        try Task.checkCancellation()

        // xcodebuild exits with a failure both when the build breaks and when a test fails. Results
        // in the bundle mean tests ran; no results mean it never got that far.
        let cases = (try? await results(in: bundle)) ?? []
        guard !cases.isEmpty else {
            if exitCode != 0 { throw BuildDeskError.buildFailed(errors: errors, logFile: log?.url.path) }
            throw BuildDeskError.unexpectedOutput(tool: "xcodebuild test", reason: "the run finished without running any test")
        }
        let elapsed = started.duration(to: .now).components
        return TestRunSummary(
            cases: cases,
            seconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / Self.attosecondsPerSecond,
            logFile: log?.url
        )
    }

    /// Streams the run, turning its output into events. Returns the tool's exit code and the
    /// build errors seen before testing began.
    private func runTests(
        _ request: TestRequest, bundle: URL, log: RunLog?, emit: @Sendable (TestEvent) -> Void
    ) async throws -> (exitCode: Int32, errors: [Diagnostic]) {
        let buildParser = BuildOutputParser()
        let testParser = TestOutputParser()
        var errors: [Diagnostic] = []
        var exitCode: Int32 = 0
        var isTesting = false
        for try await output in toolRunner.stream(AppleTools.test(request, resultBundle: bundle)) {
            switch output {
            case .line(let line):
                await log?.append(line)
                if let event = testParser.parse(line) {
                    // Announce the switch from building to testing once.
                    if !isTesting { emit(.testingStarted) }
                    isTesting = true
                    if event != .testingStarted { emit(event) }
                } else if !isTesting, let event = buildParser.parse(line) {
                    if case .diagnostic(let diagnostic) = event, diagnostic.severity == .error { errors.append(diagnostic) }
                    emit(.build(event))
                }
            case .exit(let code):
                exitCode = code
            }
        }
        return (exitCode, errors)
    }

    private func results(in bundle: URL) async throws -> [TestCaseResult] {
        let command = AppleTools.testResults(in: bundle)
        let result = try await toolRunner.run(command)
        guard result.succeeded else {
            throw BuildDeskError.toolFailed(tool: command.displayName, exitCode: result.exitCode, message: result.failureTail())
        }
        return try TestResultsParser.parse(result.stdout)
    }
}

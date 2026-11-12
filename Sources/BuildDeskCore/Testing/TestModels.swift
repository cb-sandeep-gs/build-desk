import Foundation

/// What to test and where.
public struct TestRequest: Sendable, Equatable {
    public let container: ProjectContainer
    public let scheme: String
    public let configuration: String
    public let device: Device
    /// Limits the run to these tests, each as "Bundle", "Bundle/Class" or "Bundle/Class/test".
    /// Empty runs everything the scheme tests.
    public let onlyTesting: [String]

    public init(
        container: ProjectContainer,
        scheme: String,
        configuration: String = BuildDeskConstants.fallbackConfiguration,
        device: Device,
        onlyTesting: [String] = []
    ) {
        self.container = container
        self.scheme = scheme
        self.configuration = configuration
        self.device = device
        self.onlyTesting = onlyTesting
    }
}

/// The result of one test.
public struct TestCaseResult: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable, CaseIterable {
        case passed
        case failed
        case skipped
    }

    /// One reason a test failed, with where the failing check is.
    public struct Failure: Sendable, Equatable {
        public let message: String
        public let file: String?
        public let line: Int?

        public init(message: String, file: String? = nil, line: Int? = nil) {
            self.message = message
            self.file = file
            self.line = line
        }
    }

    /// The test bundle, such as "SampleTests".
    public let bundle: String
    /// The class or suite the test is in; nested suites are joined with "/".
    public let suite: String
    /// The test's name as written in code, without the trailing "()".
    public let name: String
    public let status: Status
    public let seconds: Double
    public let failures: [Failure]

    public init(bundle: String, suite: String, name: String, status: Status, seconds: Double, failures: [Failure] = []) {
        self.bundle = bundle
        self.suite = suite
        self.name = name
        self.status = status
        self.seconds = seconds
        self.failures = failures
    }

    /// "Bundle/Class/test": what `xcodebuild -only-testing:` takes to run just this test.
    public var id: String { "\(bundle)/\(suite)/\(name)" }
}

/// Everything a finished test run found.
public struct TestRunSummary: Sendable, Equatable {
    public let cases: [TestCaseResult]
    public let seconds: Double
    /// The full output of the run, when logging is on.
    public let logFile: URL?

    public init(cases: [TestCaseResult], seconds: Double, logFile: URL?) {
        self.cases = cases
        self.seconds = seconds
        self.logFile = logFile
    }

    public func count(_ status: TestCaseResult.Status) -> Int {
        cases.filter { $0.status == status }.count
    }

    public var failed: [TestCaseResult] { cases.filter { $0.status == .failed } }
    public var succeeded: Bool { failed.isEmpty }
}

/// Progress of a test run, in the order things happen.
public enum TestEvent: Sendable, Equatable {
    /// The build that comes before the tests.
    case build(BuildEvent)
    /// The first test has started, so the build is over.
    case testingStarted
    /// One test ended. Reported live from the run's output; the final list comes with `finished`.
    case caseFinished(suite: String, name: String, status: TestCaseResult.Status)
    /// Always the last event of a run that produced results, whether or not tests failed.
    case finished(TestRunSummary)
}

import Foundation

/// What to build and where to put it.
public struct BuildRequest: Sendable, Equatable {
    public let container: ProjectContainer
    public let scheme: String
    public let configuration: String
    public let device: Device
    /// Build the scheme first. False installs the app the last build left behind, without rebuilding.
    public let builds: Bool
    /// Install the built app on the device. False means build only (frameworks, a compile check).
    public let installs: Bool
    /// Open the app after installing it.
    public let launches: Bool

    public init(
        container: ProjectContainer,
        scheme: String,
        configuration: String = BuildDeskConstants.fallbackConfiguration,
        device: Device,
        builds: Bool = true,
        installs: Bool = true,
        launches: Bool = true
    ) {
        self.container = container
        self.scheme = scheme
        self.configuration = configuration
        self.device = device
        self.builds = builds
        self.installs = installs
        self.launches = launches
    }
}

/// An error, warning or note from the build, with its source location when the tool gave one.
public struct Diagnostic: Sendable, Hashable, Codable {
    public enum Severity: String, Sendable, Codable, CaseIterable {
        case error
        case warning
        case note
    }

    public let severity: Severity
    public let message: String
    public let file: String?
    public let line: Int?
    public let column: Int?

    public init(severity: Severity, message: String, file: String? = nil, line: Int? = nil, column: Int? = nil) {
        self.severity = severity
        self.message = message
        self.file = file
        self.line = line
        self.column = column
    }
}

/// Something worth showing that one line of build output means.
public enum BuildEvent: Sendable, Equatable {
    /// Swift packages are being resolved, before any compiling starts.
    case resolvingPackages
    /// One build task started, for example "SwiftCompile" in target "Sample".
    case task(name: String, target: String)
    case diagnostic(Diagnostic)
    /// The build's own verdict line.
    case outcome(succeeded: Bool)
}

/// The app a build produced.
public struct BuiltProduct: Sendable, Equatable, Codable {
    public let appURL: URL
    public let bundleIdentifier: String

    public init(appURL: URL, bundleIdentifier: String) {
        self.appURL = appURL
        self.bundleIdentifier = bundleIdentifier
    }
}

/// The steps of one run, in order. Raw values are the words shown to the user.
public enum PipelineStep: String, Sendable, Codable, CaseIterable {
    case build
    case locate
    case install
    case launch
}

/// Progress of a run, in the order things happen.
public enum PipelineEvent: Sendable, Equatable {
    case stepStarted(PipelineStep)
    case stepFinished(PipelineStep, seconds: Double)
    case build(BuildEvent)
    /// Always the last event of a successful run.
    case finished(RunSummary)
}

/// What a finished run did.
public struct RunSummary: Sendable, Equatable {
    /// Nil for a build-only run of a scheme that has no app.
    public let product: BuiltProduct?
    public let taskCount: Int
    public let warnings: [Diagnostic]
    public let secondsByStep: [PipelineStep: Double]
    /// The full build output, when logging is on.
    public let logFile: URL?

    public init(product: BuiltProduct?, taskCount: Int, warnings: [Diagnostic], secondsByStep: [PipelineStep: Double], logFile: URL?) {
        self.product = product
        self.taskCount = taskCount
        self.warnings = warnings
        self.secondsByStep = secondsByStep
        self.logFile = logFile
    }

    public var totalSeconds: Double { secondsByStep.values.reduce(0, +) }
}

import Foundation

/// Everything that can go wrong, worded for the person using the app: what happened, then what to do.
public enum BuildDeskError: Error, Equatable, Sendable {
    /// The path is not a `.xcodeproj` or `.xcworkspace`.
    case unsupportedContainer(path: String)
    /// A project, workspace or scheme file could not be read or understood.
    case unreadableProject(path: String, reason: String)
    /// The tool could not be started at all (for example Xcode is not installed).
    case toolLaunchFailed(tool: String, reason: String)
    /// The tool ran and reported a failure.
    case toolFailed(tool: String, exitCode: Int32, message: String)
    /// The tool succeeded but its output was not in the expected shape.
    case unexpectedOutput(tool: String, reason: String)
    /// The build failed; `errors` are the compiler and tool errors found in its output.
    case buildFailed(errors: [Diagnostic], logFile: String?)
    /// The scheme built, but none of its products is an application that can be installed.
    case noApplicationProduct(scheme: String)
    /// An install without a build was asked for, but no earlier build left an app behind.
    case noBuiltProduct(scheme: String)
    /// A dropped `.app` or `.ipa` could not be read as an app.
    case unreadableArtifact(path: String, reason: String)
    /// The project's settings file names no command for this part of its release workflow.
    case releaseCommandMissing(name: String)
    /// The project's release command reported a failure, in its own words.
    case releaseFailed(message: String)
    /// Install or launch failed after a good build.
    case stepFailed(step: PipelineStep, message: String)
    /// No device matches the name or identifier the caller gave.
    case deviceNotFound(query: String)
}

extension BuildDeskError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedContainer(let path):
            "\(path) is not an Xcode project. Choose a .xcodeproj or .xcworkspace."
        case .unreadableProject(let path, let reason):
            "Couldn't read \(path): \(reason)"
        case .toolLaunchFailed(let tool, let reason):
            "Couldn't start \(tool): \(reason). Check that Xcode is installed and selected with xcode-select."
        case .toolFailed(let tool, let exitCode, let message):
            "\(tool) failed (exit \(exitCode)). \(message)"
        case .unexpectedOutput(let tool, let reason):
            "\(tool) returned output Build Desk doesn't understand: \(reason). This Xcode version may not be supported yet."
        case .buildFailed(let errors, _):
            errors.isEmpty
                ? "The build failed. Open the full log for details."
                : "The build failed with \(errors.count) error\(errors.count == 1 ? "" : "s"). First: \(errors[0].message)"
        case .noApplicationProduct(let scheme):
            "The scheme \(scheme) doesn't build an app, so there is nothing to install. Choose an app scheme."
        case .noBuiltProduct(let scheme):
            "There is no built copy of \(scheme) for this device yet. Build it once, then it can be installed again without rebuilding."
        case .unreadableArtifact(let path, let reason):
            "Couldn't read \(path) as an app: \(reason). Choose a .app or .ipa built for a device or simulator."
        case .releaseCommandMissing(let name):
            "This project's \(ProjectConfig.fileName) has no release \(name) command."
        case .releaseFailed(let message):
            message
        case .stepFailed(let step, let message):
            "The \(step.rawValue) step failed. \(message)"
        case .deviceNotFound(let query):
            "No device named or identified as \(query). Connect and unlock the device, then try again."
        }
    }
}

import Foundation

/// One tool invocation: an absolute executable path and an argument list. Never a shell string, so
/// paths with spaces and quotes need no escaping and nothing can be injected.
public struct ToolCommand: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// Short name for error messages, for example "xcrun devicectl".
    public var displayName: String {
        let tool = URL(fileURLWithPath: executable).lastPathComponent
        // xcrun is only a launcher; the tool the user knows is its first argument.
        guard executable == BuildDeskConstants.ToolPath.xcrun, let subtool = arguments.first else { return tool }
        return "\(tool) \(subtool)"
    }
}

/// The collected result of a tool that ran to completion.
public struct ToolResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { exitCode == 0 }

    /// The last lines of what the tool printed, for an error message. stderr first: tools put the
    /// reason there, and stdout is often a long progress listing.
    public func failureTail(lines: Int = BuildDeskConstants.Logs.failureTailLines) -> String {
        let text = String(decoding: stderr.isEmpty ? stdout : stderr, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).suffix(lines).joined(separator: "\n")
    }
}

/// What a streamed tool produces: its output line by line, then its exit code as the last event.
public enum ToolOutputEvent: Sendable, Equatable {
    case line(String)
    case exit(Int32)
}

/// The single doorway to every Apple tool. Core logic depends on this protocol only, so tests run
/// with a fake and never need Xcode or a device.
public protocol ToolRunning: Sendable {
    /// Runs a tool to completion and returns everything it printed.
    func run(_ command: ToolCommand) async throws -> ToolResult

    /// Runs a tool and delivers its output (stdout and stderr together) as it is printed. Ending
    /// the iteration early, or cancelling the task that iterates, stops the tool.
    func stream(_ command: ToolCommand) -> AsyncThrowingStream<ToolOutputEvent, Error>
}

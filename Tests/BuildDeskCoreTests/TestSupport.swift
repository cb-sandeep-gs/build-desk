@testable import BuildDeskCore
import Foundation

/// Stands in for the Apple tools: records every command and answers from closures, so tests never
/// need Xcode, a device or the network.
final class FakeToolRunner: ToolRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ToolCommand] = []

    /// Answer for tools run to completion. Set before the runner is used.
    var onRun: @Sendable (ToolCommand) throws -> ToolResult = { _ in ToolResult(exitCode: 0) }
    /// Output for streamed tools. Set before the runner is used.
    var onStream: @Sendable (ToolCommand) -> [ToolOutputEvent] = { _ in [.exit(0)] }

    var commands: [ToolCommand] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(_ command: ToolCommand) async throws -> ToolResult {
        record(command)
        return try onRun(command)
    }

    func stream(_ command: ToolCommand) -> AsyncThrowingStream<ToolOutputEvent, Error> {
        record(command)
        let events = onStream(command)
        return AsyncThrowingStream { continuation in
            events.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    private func record(_ command: ToolCommand) {
        lock.lock()
        recorded.append(command)
        lock.unlock()
    }
}

extension ToolCommand {
    /// The tool and its arguments as one string, for readable assertions.
    var text: String { ([URL(fileURLWithPath: executable).lastPathComponent] + arguments).joined(separator: " ") }
}

/// Made-up devices. No real identifier or device name belongs in this repository.
enum Sample {
    static let phoneID = "00008000-0000000000000001"
    static let simulatorID = "11111111-2222-3333-4444-555555555555"

    static let phone = Device(
        id: phoneID, name: "Test iPhone", model: "iPhone 17", platform: "iOS", osVersion: "27.2",
        kind: .physical, connection: .wired, isReady: true, isBooted: true
    )
    static let simulator = Device(
        id: simulatorID, name: "iPhone 17 Pro", model: "iPhone 17 Pro", platform: "iOS", osVersion: "27.2",
        kind: .simulator, connection: .local, isReady: true, isBooted: false
    )

    static func container(_ name: String = "Sample.xcodeproj") throws -> ProjectContainer {
        try ProjectContainer(url: URL(fileURLWithPath: "/projects/\(name)"))
    }
}

/// A folder that is deleted when the test ends.
struct TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("builddesk-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func write(_ text: String, to path: String) throws -> URL {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

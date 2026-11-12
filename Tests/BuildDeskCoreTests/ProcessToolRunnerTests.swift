@testable import BuildDeskCore
import XCTest

/// These run small system tools (`/bin/sh`, `/bin/sleep`) that every Mac has; they need no Xcode.
final class ProcessToolRunnerTests: XCTestCase {
    private let runner = ProcessToolRunner()

    private func shell(_ script: String) -> ToolCommand {
        ToolCommand(executable: "/bin/sh", arguments: ["-c", script])
    }

    func testRunCollectsOutputAndExitCode() async throws {
        let result = try await runner.run(shell("printf 'out'; printf 'err' >&2; exit 3"))

        XCTAssertEqual(result.exitCode, 3)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "out")
        XCTAssertEqual(result.failureTail(), "err")
    }

    func testRunHandlesOutputLargerThanAPipeBuffer() async throws {
        // 200,000 lines is far more than a pipe holds; this would hang if output were not drained.
        let result = try await runner.run(shell("seq 1 200000"))

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout.split(separator: UInt8(ascii: "\n")).count, 200_000)
    }

    func testArgumentsAreNotInterpretedByAShell() async throws {
        let result = try await runner.run(ToolCommand(executable: "/bin/echo", arguments: ["a b", "$HOME; ls"]))
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "a b $HOME; ls\n")
    }

    func testMissingToolIsALaunchFailure() async {
        do {
            _ = try await runner.run(ToolCommand(executable: "/no/such/tool", arguments: []))
            XCTFail("expected a failure")
        } catch {
            guard case BuildDeskError.toolLaunchFailed(let tool, _) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(tool, "tool")
        }
    }

    func testStreamDeliversLinesInOrderThenTheExitCode() async throws {
        var events: [ToolOutputEvent] = []
        // stderr is merged in order, "\r\n" endings are trimmed, and a last line without a newline still arrives.
        for try await event in runner.stream(shell("echo one; echo two >&2; printf 'three\\r\\n'; printf 'tail'; exit 2")) {
            events.append(event)
        }
        XCTAssertEqual(events, [.line("one"), .line("two"), .line("three"), .line("tail"), .exit(2)])
    }

    func testStreamOfAMissingToolThrows() async {
        do {
            for try await _ in runner.stream(ToolCommand(executable: "/no/such/tool", arguments: [])) {}
            XCTFail("expected a failure")
        } catch {
            guard case BuildDeskError.toolLaunchFailed = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    func testCancellingTheConsumerStopsTheTool() async throws {
        let runner = runner
        let started = ContinuousClock.now
        let task = Task {
            for try await _ in runner.stream(ToolCommand(executable: "/bin/sleep", arguments: ["30"])) {}
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        _ = await task.result

        // Far less than the 30 seconds the tool would have run.
        XCTAssertLessThan(started.duration(to: .now), .seconds(10))
    }

    func testCancellingARunStopsTheTool() async throws {
        let runner = runner
        let started = ContinuousClock.now
        let task = Task { try await runner.run(ToolCommand(executable: "/bin/sleep", arguments: ["30"])) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let result = await task.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertLessThan(started.duration(to: .now), .seconds(10))
    }
}

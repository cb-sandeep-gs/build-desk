import Foundation

/// Runs tools as real child processes.
public struct ProcessToolRunner: ToolRunning {
    public init() {}

    public func run(_ command: ToolCommand) async throws -> ToolResult {
        // Output goes to temporary files, not pipes: a pipe that nobody drains blocks the tool once
        // it fills, and some tools print megabytes (build settings, device lists).
        let capture = try OutputCapture()
        defer { capture.remove() }
        let box = ProcessBox(command: command)
        box.process.standardOutput = capture.stdout
        box.process.standardError = capture.stderr

        let exitCode: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try box.launch()
                } catch {
                    box.process.terminationHandler = nil
                    continuation.resume(throwing: BuildDeskError.toolLaunchFailed(
                        tool: command.displayName, reason: error.localizedDescription
                    ))
                }
            }
        } onCancel: {
            box.terminate()
        }
        try Task.checkCancellation()
        return ToolResult(exitCode: exitCode, stdout: capture.readStdout(), stderr: capture.readStderr())
    }

    public func stream(_ command: ToolCommand) -> AsyncThrowingStream<ToolOutputEvent, Error> {
        AsyncThrowingStream { continuation in
            let session = StreamSession(command: command, continuation: continuation)
            // Runs when the consumer stops iterating or its task is cancelled, and also after a
            // normal finish (where the process has already exited and this does nothing).
            continuation.onTermination = { _ in session.cancel() }
            session.start()
        }
    }
}

/// A `Process` that can be stopped from another thread. `Process.terminate()` raises an Objective-C
/// exception when the process was never launched, so launch and terminate are guarded together.
private final class ProcessBox: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var isLaunched = false
    private var isCancelled = false

    init(command: ToolCommand) {
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        // No stdin: a tool that asks a question must fail instead of waiting forever.
        process.standardInput = FileHandle.nullDevice
    }

    func launch() throws {
        lock.lock()
        defer { lock.unlock() }
        try process.run()
        isLaunched = true
        // Cancelled between creation and launch: stop it now instead of letting it run to the end.
        if isCancelled { process.terminate() }
    }

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
        if isLaunched, process.isRunning { process.terminate() }
    }
}

/// Temporary files that receive a tool's stdout and stderr.
private struct OutputCapture {
    private let stdoutURL: URL
    private let stderrURL: URL
    let stdout: FileHandle
    let stderr: FileHandle

    init() throws {
        let folder = FileManager.default.temporaryDirectory
        let name = "builddesk-\(UUID().uuidString)"
        stdoutURL = folder.appendingPathComponent("\(name).out")
        stderrURL = folder.appendingPathComponent("\(name).err")
        for url in [stdoutURL, stderrURL] {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        stdout = try FileHandle(forWritingTo: stdoutURL)
        stderr = try FileHandle(forWritingTo: stderrURL)
    }

    func readStdout() -> Data { (try? Data(contentsOf: stdoutURL)) ?? Data() }
    func readStderr() -> Data { (try? Data(contentsOf: stderrURL)) ?? Data() }

    func remove() {
        for handle in [stdout, stderr] { try? handle.close() }
        for url in [stdoutURL, stderrURL] { try? FileManager.default.removeItem(at: url) }
    }
}

/// One streamed tool run: reads the pipe as output arrives, splits it into lines and finishes the
/// stream once the process has exited and its output has ended.
private final class StreamSession: @unchecked Sendable {
    private static let newline = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")

    private let command: ToolCommand
    private let box: ProcessBox
    private let pipe = Pipe()
    private let continuation: AsyncThrowingStream<ToolOutputEvent, Error>.Continuation

    private let lock = NSLock()
    /// Bytes after the last complete line.
    private var pending = Data()
    private var exitCode: Int32?
    private var outputEnded = false
    private var isFinished = false

    init(command: ToolCommand, continuation: AsyncThrowingStream<ToolOutputEvent, Error>.Continuation) {
        self.command = command
        self.box = ProcessBox(command: command)
        self.continuation = continuation
    }

    func start() {
        // One pipe for both, so errors appear in order with the output around them.
        box.process.standardOutput = pipe
        box.process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            // An empty read means every writer closed the pipe.
            if data.isEmpty { markOutputEnded() } else { receive(data) }
        }
        box.process.terminationHandler = { [self] process in
            markExited(process.terminationStatus)
        }
        do {
            try box.launch()
        } catch {
            detachHandlers()
            continuation.finish(throwing: BuildDeskError.toolLaunchFailed(
                tool: command.displayName, reason: error.localizedDescription
            ))
        }
    }

    func cancel() {
        box.terminate()
    }

    private func receive(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        pending.append(data)
        for line in takeLines(includingPartial: false) { continuation.yield(.line(line)) }
    }

    private func markOutputEnded() {
        lock.lock()
        outputEnded = true
        lock.unlock()
        finishIfReady(force: false)
    }

    private func markExited(_ code: Int32) {
        lock.lock()
        exitCode = code
        lock.unlock()
        finishIfReady(force: false)
        // If a child of the tool still holds the pipe, the end of output never comes; finish anyway.
        DispatchQueue.global().asyncAfter(deadline: .now() + BuildDeskConstants.outputDrainGrace) { [self] in
            finishIfReady(force: true)
        }
    }

    private func finishIfReady(force: Bool) {
        lock.lock()
        guard !isFinished, let exitCode, outputEnded || force else {
            lock.unlock()
            return
        }
        isFinished = true
        for line in takeLines(includingPartial: true) { continuation.yield(.line(line)) }
        continuation.yield(.exit(exitCode))
        lock.unlock()
        detachHandlers()
        continuation.finish()
    }

    /// Breaks the retain cycle between this session and the process and pipe callbacks.
    private func detachHandlers() {
        pipe.fileHandleForReading.readabilityHandler = nil
        box.process.terminationHandler = nil
    }

    /// Removes and returns the complete lines in `pending`. Call with the lock held.
    private func takeLines(includingPartial: Bool) -> [String] {
        var lines: [String] = []
        if let lastNewline = pending.lastIndex(of: Self.newline) {
            let complete = pending[pending.startIndex..<lastNewline]
            lines = complete.split(separator: Self.newline, omittingEmptySubsequences: false).map(Self.decode)
            pending = Data(pending[pending.index(after: lastNewline)...])
        }
        if includingPartial, !pending.isEmpty {
            lines.append(Self.decode(pending))
            pending.removeAll()
        }
        return lines
    }

    private static func decode(_ bytes: Data) -> String {
        var bytes = bytes
        if bytes.last == carriageReturn { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }
}

@testable import BuildDeskCore
import XCTest

final class DeviceToolsTests: XCTestCase {
    /// The shape `devicectl device info files --json-output` writes, with made-up names.
    private let filesJSON = """
    {"result":{"deviceIdentifier":"X","domain":"systemCrashLogs","files":[
      {"name":"Sample-2026-01-02-101500.ips","relativePath":"Sample-2026-01-02-101500.ips",
       "metadata":{"lastModDate":"2026-01-02T10:15:00.000Z","size":34395},"resources":{"isDirectory":false}},
      {"name":"Sample-2026-01-05-080000.ips","relativePath":"Sample-2026-01-05-080000.ips",
       "metadata":{"lastModDate":"2026-01-05T08:00:00.000Z","size":1200},"resources":{"isDirectory":false}},
      {"name":"SampleKit-2026-01-06-080000.ips","relativePath":"SampleKit-2026-01-06-080000.ips",
       "metadata":{"lastModDate":"2026-01-06T08:00:00.000Z","size":10},"resources":{"isDirectory":false}},
      {"name":"Sample-2026-01-07.log","relativePath":"Sample-2026-01-07.log","resources":{"isDirectory":false}},
      {"name":"Retired","relativePath":"Retired","resources":{"isDirectory":true}}
    ]}}
    """

    /// A runner that writes the file listing where devicectl is told to.
    private func runner() -> FakeToolRunner {
        let runner = FakeToolRunner()
        let json = filesJSON
        runner.onRun = { command in
            if let index = command.arguments.firstIndex(of: "--json-output") {
                try Data(json.utf8).write(to: URL(fileURLWithPath: command.arguments[index + 1]))
            }
            return ToolResult(exitCode: 0)
        }
        return runner
    }

    func testScreenshotUsesTheToolForTheKindOfDevice() async throws {
        let runner = runner()
        let tools = DeviceToolsService(toolRunner: runner)
        let file = URL(fileURLWithPath: "/pictures/shot.png")

        try await tools.screenshot(of: Sample.phone, to: file)
        try await tools.screenshot(of: Sample.simulator, to: file)

        XCTAssertEqual(runner.commands.map(\.text), [
            "xcrun devicectl device capture screenshot --device \(Sample.phoneID) --destination /pictures/shot.png",
            "xcrun simctl io \(Sample.simulatorID) screenshot /pictures/shot.png",
        ])
    }

    func testAFailingToolIsReportedWithItsReason() async {
        let runner = FakeToolRunner()
        runner.onRun = { _ in ToolResult(exitCode: 1, stderr: Data("The device is locked.".utf8)) }
        do {
            try await DeviceToolsService(toolRunner: runner).screenshot(of: Sample.phone, to: URL(fileURLWithPath: "/x.png"))
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? BuildDeskError, .toolFailed(tool: "xcrun devicectl", exitCode: 1, message: "The device is locked."))
        }
    }

    func testCrashLogsOfTheProcessComeNewestFirst() async throws {
        let logs = try await DeviceToolsService(toolRunner: runner()).crashLogs(forProcess: "Sample", on: Sample.phone)

        // Not "SampleKit", not the .log file, not the folder.
        XCTAssertEqual(logs.map(\.name), ["Sample-2026-01-05-080000.ips", "Sample-2026-01-02-101500.ips"])
        XCTAssertEqual(logs.first?.bytes, 1200)
        XCTAssertEqual(logs.first?.date, ISO8601DateFormatter().date(from: "2026-01-05T08:00:00Z"))
    }

    func testDeviceCrashLogsAndAppDataAreCopiedWithTheRightDomain() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let runner = runner()
        let tools = DeviceToolsService(toolRunner: runner)

        let logsFolder = folder.url.appendingPathComponent("logs")
        let dataFolder = folder.url.appendingPathComponent("data")
        try await tools.copy([CrashLog(name: "Sample-2026-01-05-080000.ips")], from: Sample.phone, to: logsFolder)
        try await tools.copyAppData(bundleIdentifier: "com.example.sample", from: Sample.phone, to: dataFolder)

        let logs = logsFolder.path
        let data = dataFolder.path
        XCTAssertEqual(runner.commands.map(\.text), [
            "xcrun devicectl device copy from --device \(Sample.phoneID) --domain-type systemCrashLogs "
                + "--source Sample-2026-01-05-080000.ips --destination \(logs)/Sample-2026-01-05-080000.ips",
            "xcrun devicectl device copy from --device \(Sample.phoneID) --domain-type appDataContainer "
                + "--domain-identifier com.example.sample --source . --destination \(data)",
        ])
        // The destination folders exist before the tool is asked to write into them.
        XCTAssertTrue(FileManager.default.fileExists(atPath: logs))
    }

    func testSimulatorFilesAreReadFromThisMac() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.write("crash", to: "reports/Sample-2026-01-05-080000.ips")
        try folder.write("other", to: "reports/Other-2026-01-05-080000.ips")
        try folder.write("{}", to: "container/Library/Preferences/settings.plist")
        try folder.write("doc", to: "container/Documents/note.txt")
        let runner = FakeToolRunner()
        let container = folder.url.appendingPathComponent("container").path
        runner.onRun = { _ in ToolResult(exitCode: 0, stdout: Data("\(container)\n".utf8)) }
        let tools = DeviceToolsService(toolRunner: runner, simulatorReportsFolder: folder.url.appendingPathComponent("reports"))

        let logs = try await tools.crashLogs(forProcess: "Sample", on: Sample.simulator)
        XCTAssertEqual(logs.map(\.name), ["Sample-2026-01-05-080000.ips"])
        XCTAssertNotNil(logs.first?.date)

        try await tools.copy(logs, from: Sample.simulator, to: folder.url.appendingPathComponent("saved"))
        let dataFolder = folder.url.appendingPathComponent("data")
        try await tools.copyAppData(bundleIdentifier: "com.example.sample", from: Sample.simulator, to: dataFolder)

        let files = FileManager.default
        XCTAssertTrue(files.fileExists(atPath: folder.url.appendingPathComponent("saved/Sample-2026-01-05-080000.ips").path))
        XCTAssertTrue(files.fileExists(atPath: folder.url.appendingPathComponent("data/Library/Preferences/settings.plist").path))
        XCTAssertTrue(files.fileExists(atPath: folder.url.appendingPathComponent("data/Documents/note.txt").path))
        // Only the container lookup ran as a tool; crash logs needed none.
        XCTAssertEqual(runner.commands.map(\.text), ["xcrun simctl get_app_container \(Sample.simulatorID) com.example.sample data"])
    }

    func testAnUnexpectedFileListingIsReportedAsSuch() {
        XCTAssertThrowsError(try DeviceFilesParser.parse(Data("{}".utf8))) { error in
            guard case BuildDeskError.unexpectedOutput = error else { return XCTFail("wrong error: \(error)") }
        }
    }
}

@testable import BuildDeskCore
import XCTest

final class TestRunnerTests: XCTestCase {
    /// The shape `xcresulttool get test-results tests` prints, with made-up names.
    private let resultsJSON = """
    {"devices":[{"deviceName":"Test Mac"}],
     "testNodes":[{"name":"Sample","nodeType":"Test Plan","result":"Failed","children":[
       {"name":"SampleTests","nodeType":"Unit test bundle","result":"Failed","children":[
         {"name":"CartTests","nodeType":"Test Suite","result":"Failed","children":[
           {"name":"testAddItem()","nodeType":"Test Case","result":"Passed","durationInSeconds":0.012},
           {"name":"testTotal()","nodeType":"Test Case","result":"Failed","durationInSeconds":0.5,"children":[
             {"name":"XCTAssertEqual failed: (\\"2\\") is not equal to (\\"3\\")","nodeType":"Failure Message",
              "sourceLocation":{"filePath":"/src/Tests/CartTests.swift","lineNumber":64}},
             {"name":"second check failed","nodeType":"Failure Message"}]},
           {"name":"testLater()","nodeType":"Test Case","result":"Skipped","durationInSeconds":0.001,"children":[
             {"name":"Test skipped - not ready","nodeType":"Skip Message"}]},
           {"name":"testKnownIssue()","nodeType":"Test Case","result":"Expected Failure","durationInSeconds":0.1}]},
         {"name":"Outer","nodeType":"Test Suite","result":"Passed","children":[
           {"name":"Inner","nodeType":"Test Suite","result":"Passed","children":[
             {"name":"checksNested","nodeType":"Test Case","result":"Passed","durationInSeconds":0.2}]}]}]},
       {"name":"SampleUITests","nodeType":"UI test bundle","result":"Passed","children":[
         {"name":"LaunchTests","nodeType":"Test Suite","result":"Passed","children":[
           {"name":"testLaunches()","nodeType":"Test Case","result":"Passed","durationInSeconds":4.2}]}]}]}]}
    """

    func testResultsAreReadFromTheTree() throws {
        let cases = try TestResultsParser.parse(Data(resultsJSON.utf8))

        XCTAssertEqual(cases.map(\.id), [
            "SampleTests/CartTests/testAddItem", "SampleTests/CartTests/testTotal", "SampleTests/CartTests/testLater",
            "SampleTests/CartTests/testKnownIssue", "SampleTests/Outer/Inner/checksNested", "SampleUITests/LaunchTests/testLaunches",
        ])
        // An expected failure does not fail the run.
        XCTAssertEqual(cases.map(\.status), [.passed, .failed, .skipped, .passed, .passed, .passed])
        XCTAssertEqual(cases[1].failures, [
            .init(message: "XCTAssertEqual failed: (\"2\") is not equal to (\"3\")", file: "/src/Tests/CartTests.swift", line: 64),
            .init(message: "second check failed"),
        ])
        // A skip message is not a failure.
        XCTAssertTrue(cases[2].failures.isEmpty)
        XCTAssertEqual(cases[5].seconds, 4.2)
        XCTAssertThrowsError(try TestResultsParser.parse(Data("[]".utf8)))
    }

    func testLiveOutputLines() {
        let parser = TestOutputParser()
        XCTAssertEqual(parser.parse("Test Case '-[SampleTests.CartTests testAddItem]' started."), .testingStarted)
        XCTAssertEqual(
            parser.parse("Test Case '-[SampleTests.CartTests testAddItem]' passed (0.012 seconds)."),
            .caseFinished(suite: "CartTests", name: "testAddItem", status: .passed)
        )
        XCTAssertEqual(
            parser.parse("Test Case '-[CartTests testTotal]' failed (0.500 seconds)."),
            .caseFinished(suite: "CartTests", name: "testTotal", status: .failed)
        )
        XCTAssertEqual(
            parser.parse("Test Case '-[SampleTests.CartTests testLater]' skipped (0.001 seconds)."),
            .caseFinished(suite: "CartTests", name: "testLater", status: .skipped)
        )
        XCTAssertNil(parser.parse("Test Suite 'CartTests' passed at 2026-01-01 10:00:00.000."))
        XCTAssertNil(parser.parse("Test suite 'CartTests' started on 'Clone 1 of iPhone 17 - Sample (123)'"))
        XCTAssertNil(parser.parse("/src/Tests/CartTests.swift:64: error: -[SampleTests.CartTests testTotal] : failed"))
    }

    func testLiveOutputLinesOfParallelRunsOnSimulators() {
        let parser = TestOutputParser()
        XCTAssertEqual(parser.parse("Testing started"), .testingStarted)
        XCTAssertEqual(
            parser.parse("Test case 'CartTests.testAddItem()' passed on 'Clone 1 of iPhone 17 - Sample (123)' (0.007 seconds)"),
            .caseFinished(suite: "CartTests", name: "testAddItem", status: .passed)
        )
        XCTAssertEqual(
            parser.parse("Test case 'Outer.Inner.checksNested()' failed on 'Clone 2 of iPhone 17 - Sample (124)' (1.2 seconds)"),
            .caseFinished(suite: "Inner", name: "checksNested", status: .failed)
        )
        XCTAssertEqual(
            parser.parse("Test case 'CartTests.testLater()' skipped on 'iPhone 17' (0.001 seconds)"),
            .caseFinished(suite: "CartTests", name: "testLater", status: .skipped)
        )
    }

    /// A runner that plays a test run and answers the results query.
    private func runner(lines: [String], exit: Int32, results: String?) -> FakeToolRunner {
        let runner = FakeToolRunner()
        runner.onStream = { _ in lines.map(ToolOutputEvent.line) + [.exit(exit)] }
        runner.onRun = { _ in
            results.map { ToolResult(exitCode: 0, stdout: Data($0.utf8)) } ?? ToolResult(exitCode: 1, stderr: Data("no bundle".utf8))
        }
        return runner
    }

    private func request(only: [String] = [], device: Device = Sample.simulator) throws -> TestRequest {
        TestRequest(container: try Sample.container(), scheme: "Sample", configuration: "Debug", device: device, onlyTesting: only)
    }

    private func events(_ runner: FakeToolRunner, _ request: TestRequest, results: URL) async throws -> [TestEvent] {
        var events: [TestEvent] = []
        for try await event in TestRunner(toolRunner: runner, logDirectory: nil, resultsDirectory: results).run(request) {
            events.append(event)
        }
        return events
    }

    func testARunWithFailuresStillEndsWithResults() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let runner = runner(lines: [
            "SwiftCompile normal arm64 /src/Cart.swift (in target 'Sample' from project 'Sample')",
            "Test Case '-[SampleTests.CartTests testAddItem]' started.",
            "Test Case '-[SampleTests.CartTests testAddItem]' passed (0.012 seconds).",
            // After testing starts, lines that look like build output are not build events.
            "Ld /derived/Sample (in target 'Sample' from project 'Sample')",
            "Test Case '-[SampleTests.CartTests testTotal]' failed (0.500 seconds).",
            "** TEST FAILED **",
        ], exit: 65, results: resultsJSON)

        let events = try await events(runner, request(only: ["SampleTests/CartTests"]), results: folder.url)

        XCTAssertEqual(Array(events.dropLast()), [
            .build(.task(name: "SwiftCompile", target: "Sample")),
            .testingStarted,
            .caseFinished(suite: "CartTests", name: "testAddItem", status: .passed),
            .caseFinished(suite: "CartTests", name: "testTotal", status: .failed),
        ])
        guard case .finished(let summary) = events.last else { return XCTFail("no summary") }
        XCTAssertEqual(summary.count(.passed), 4)
        XCTAssertEqual(summary.failed.map(\.name), ["testTotal"])
        XCTAssertFalse(summary.succeeded)

        let test = runner.commands[0]
        XCTAssertEqual(test.arguments.suffix(2), ["-only-testing:SampleTests/CartTests", "test"])
        XCTAssertFalse(test.arguments.contains("-allowProvisioningUpdates"))
        XCTAssertFalse(test.arguments.contains("-derivedDataPath"))
        // The results are read from the bundle the test run was told to write.
        let bundle = try XCTUnwrap(test.arguments.firstIndex(of: "-resultBundlePath").map { test.arguments[$0 + 1] })
        XCTAssertEqual(runner.commands[1].arguments, ["xcresulttool", "get", "test-results", "tests", "--path", bundle])
        XCTAssertTrue(bundle.hasPrefix(folder.url.path))
    }

    func testABuildThatBreaksBeforeAnyTestIsABuildFailure() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let lines = ["/src/Cart.swift:3:1: error: cannot find 'total' in scope", "** TEST FAILED **"]
        let runner = runner(lines: lines, exit: 65, results: nil)
        do {
            _ = try await events(runner, request(device: Sample.phone), results: folder.url)
            XCTFail("expected a failure")
        } catch let error as BuildDeskError {
            guard case .buildFailed(let errors, _) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(errors.map(\.message), ["cannot find 'total' in scope"])
        }
        XCTAssertTrue(runner.commands[0].arguments.contains("-allowProvisioningUpdates"))
    }

    func testARunThatRanNothingSaysSo() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let runner = runner(lines: ["** TEST SUCCEEDED **"], exit: 0, results: #"{"testNodes":[]}"#)
        do {
            _ = try await events(runner, request(), results: folder.url)
            XCTFail("expected a failure")
        } catch {
            guard case BuildDeskError.unexpectedOutput = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    func testTheResultBundleIsDeletedAfterItIsRead() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let runner = runner(lines: [], exit: 0, results: resultsJSON)
        runner.onStream = { command in
            // As the real tool does: write the bundle where it was told to.
            if let index = command.arguments.firstIndex(of: "-resultBundlePath") {
                try? FileManager.default.createDirectory(atPath: command.arguments[index + 1], withIntermediateDirectories: true)
            }
            return [.exit(0)]
        }

        _ = try await events(runner, request(), results: folder.url)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.url.path), [])
    }
}

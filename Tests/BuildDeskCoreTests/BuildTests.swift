@testable import BuildDeskCore
import XCTest

final class BuildParserTests: XCTestCase {
    private let parser = BuildOutputParser()

    func testRecognisedLinesBecomeEvents() {
        XCTAssertEqual(parser.parse("Resolve Package Graph"), .resolvingPackages)
        XCTAssertEqual(parser.parse("** BUILD SUCCEEDED **"), .outcome(succeeded: true))
        XCTAssertEqual(parser.parse("** BUILD FAILED **"), .outcome(succeeded: false))
        XCTAssertEqual(
            parser.parse("CodeSign /derived/Sample.app (in target 'Sample' from project 'Sample')"),
            .task(name: "CodeSign", target: "Sample")
        )
    }

    func testOrdinaryOutputIsNotAnEvent() {
        XCTAssertNil(parser.parse(""))
        XCTAssertNil(parser.parse("    cd /src"))
        XCTAssertNil(parser.parse("Command line invocation:"))
        // "warning: " in the middle of a sentence is not a diagnostic.
        XCTAssertNil(parser.parse("note that this prints warning: nothing"))
    }

    func testDiagnosticsCarryTheirLocation() {
        XCTAssertEqual(
            parser.parse("/src/App/Home.swift:41:13: warning: 'load()' is deprecated"),
            .diagnostic(Diagnostic(
                severity: .warning, message: "'load()' is deprecated", file: "/src/App/Home.swift", line: 41, column: 13
            ))
        )
        // A colon inside the path must not shift the line and column.
        XCTAssertEqual(
            parser.parse("/src/A:B/Home.swift:7:1: error: broken"),
            .diagnostic(Diagnostic(severity: .error, message: "broken", file: "/src/A:B/Home.swift", line: 7, column: 1))
        )
        XCTAssertEqual(
            parser.parse("error: No profiles for 'com.example.sample' were found"),
            .diagnostic(Diagnostic(severity: .error, message: "No profiles for 'com.example.sample' were found"))
        )
        XCTAssertEqual(
            parser.parse("/src/Sample.xcodeproj: warning: project needs an update"),
            .diagnostic(Diagnostic(severity: .warning, message: "project needs an update", file: "/src/Sample.xcodeproj"))
        )
    }

    func testBuildSettingsGiveTheApplicationProduct() throws {
        let product = try BuildSettingsParser.product(in: Data(Fixtures.buildSettings.utf8), scheme: "Sample")

        // The extension comes first in the list; the application is what gets installed.
        XCTAssertEqual(product.appURL.path, "/derived/Build/Products/Debug-iphoneos/Sample.app")
        XCTAssertEqual(product.bundleIdentifier, "com.example.sample")
    }

    func testSchemeWithoutAnApplicationCannotBeInstalled() {
        let frameworkOnly = #"[{"buildSettings":{"PRODUCT_TYPE":"com.apple.product-type.framework"}}]"#
        XCTAssertThrowsError(try BuildSettingsParser.product(in: Data(frameworkOnly.utf8), scheme: "SampleKit")) { error in
            XCTAssertEqual(error as? BuildDeskError, .noApplicationProduct(scheme: "SampleKit"))
        }
        XCTAssertThrowsError(try BuildSettingsParser.product(in: Data("oops".utf8), scheme: "Sample")) { error in
            guard case BuildDeskError.unexpectedOutput = error else { return XCTFail("wrong error: \(error)") }
        }
    }
}

final class AppleToolsTests: XCTestCase {
    func testDeviceBuildAllowsProvisioningAndKeepsXcodeDerivedData() throws {
        let request = BuildRequest(
            container: try Sample.container(), scheme: "My App", configuration: "Staging Debug", device: Sample.phone
        )

        XCTAssertEqual(AppleTools.build(request).arguments, [
            "-project", "/projects/Sample.xcodeproj",
            "-scheme", "My App",
            "-configuration", "Staging Debug",
            "-destination", "id=\(Sample.phoneID)",
            "-allowProvisioningUpdates",
            "build",
        ])
        XCTAssertFalse(AppleTools.build(request).arguments.contains("-derivedDataPath"))
        // The settings query must describe the same build.
        XCTAssertEqual(AppleTools.buildSettings(request).arguments.dropLast(2), AppleTools.build(request).arguments.dropLast())
    }

    func testSimulatorBuildOfAWorkspaceIsNotProvisioned() throws {
        let request = BuildRequest(container: try Sample.container("App.xcworkspace"), scheme: "Sample", device: Sample.simulator)
        let arguments = AppleTools.build(request).arguments

        XCTAssertEqual(Array(arguments.prefix(2)), ["-workspace", "/projects/App.xcworkspace"])
        XCTAssertFalse(arguments.contains("-allowProvisioningUpdates"))
        XCTAssertTrue(arguments.contains("Debug"))
    }

    func testToolNamesForMessages() throws {
        XCTAssertEqual(AppleTools.listSimulators().displayName, "xcrun simctl")
        XCTAssertEqual(AppleTools.listProject(try Sample.container()).displayName, "xcodebuild")
    }
}

final class BuildPipelineTests: XCTestCase {
    private func runner(build lines: [String] = Fixtures.buildOutput, exit: Int32 = 0) -> FakeToolRunner {
        let runner = FakeToolRunner()
        runner.onStream = { _ in lines.map(ToolOutputEvent.line) + [.exit(exit)] }
        runner.onRun = { command in
            command.arguments.contains("-showBuildSettings")
                ? ToolResult(exitCode: 0, stdout: Data(Fixtures.buildSettings.utf8))
                : ToolResult(exitCode: 0)
        }
        return runner
    }

    private func request(
        device: Device = Sample.phone, builds: Bool = true, installs: Bool = true, launches: Bool = true
    ) throws -> BuildRequest {
        BuildRequest(
            container: try Sample.container(), scheme: "Sample", device: device, builds: builds, installs: installs, launches: launches
        )
    }

    /// Runs the pipeline to its end and returns the events as short labels (durations vary).
    private func events(
        _ runner: FakeToolRunner, _ request: BuildRequest, builtAppExists: Bool = true
    ) async throws -> (labels: [String], summary: RunSummary?) {
        var labels: [String] = []
        var summary: RunSummary?
        let pipeline = BuildPipeline(toolRunner: runner, logDirectory: nil) { _ in builtAppExists }
        for try await event in pipeline.run(request) {
            switch event {
            case .stepStarted(let step): labels.append("start \(step.rawValue)")
            case .stepFinished(let step, _): labels.append("end \(step.rawValue)")
            case .build, .deviceFinished: break
            case .finished(let finished): summary = finished
            }
        }
        return (labels, summary)
    }

    func testRunOnADeviceBuildsInstallsAndLaunches() async throws {
        let runner = runner()
        let (labels, summary) = try await events(runner, request())

        XCTAssertEqual(labels, [
            "start build", "end build", "start locate", "end locate",
            "start install", "end install", "start launch", "end launch",
        ])
        let app = "/derived/Build/Products/Debug-iphoneos/Sample.app"
        XCTAssertEqual(runner.commands.dropFirst(2).map(\.text), [
            "xcrun devicectl device install app --device \(Sample.phoneID) \(app)",
            "xcrun devicectl device process launch --device \(Sample.phoneID) --terminate-existing com.example.sample",
        ])
        XCTAssertEqual(summary?.product?.bundleIdentifier, "com.example.sample")
        XCTAssertEqual(summary?.taskCount, 3)
        // The same warning printed twice is one warning.
        XCTAssertEqual(summary?.warnings.count, 1)
        XCTAssertEqual(summary.map { Set($0.secondsByStep.keys) }, Set(PipelineStep.allCases))
    }

    func testRunOnASimulatorBootsItFirst() async throws {
        let runner = runner()
        _ = try await events(runner, request(device: Sample.simulator))

        XCTAssertEqual(runner.commands.dropFirst(2).map(\.text), [
            "xcrun simctl bootstatus \(Sample.simulatorID) -b",
            "xcrun simctl install \(Sample.simulatorID) /derived/Build/Products/Debug-iphoneos/Sample.app",
            "xcrun simctl launch --terminate-running-process \(Sample.simulatorID) com.example.sample",
        ])
    }

    func testBuildOnlyAndNoLaunchStopEarly() async throws {
        let buildOnly = runner()
        let (buildLabels, summary) = try await events(buildOnly, request(installs: false))
        XCTAssertEqual(buildLabels, ["start build", "end build"])
        XCTAssertNil(summary?.product)
        XCTAssertEqual(buildOnly.commands.count, 1)

        let (noLaunchLabels, _) = try await events(runner(), request(launches: false))
        XCTAssertEqual(noLaunchLabels.last, "end install")
    }

    func testInstallOnlySkipsTheBuildAndUsesTheLastOne() async throws {
        let runner = runner()
        let (labels, summary) = try await events(runner, request(builds: false))

        XCTAssertEqual(labels, ["start locate", "end locate", "start install", "end install", "start launch", "end launch"])
        // No build ran, so nothing was streamed and there is no build log.
        XCTAssertFalse(runner.commands.contains { $0.arguments.last == "build" })
        XCTAssertEqual(summary?.taskCount, 0)
        XCTAssertNil(summary?.logFile)
        XCTAssertEqual(summary?.product?.bundleIdentifier, "com.example.sample")
    }

    func testInstallOnlyWithoutAnEarlierBuildSaysSo() async throws {
        let runner = runner()
        do {
            _ = try await events(runner, request(builds: false), builtAppExists: false)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? BuildDeskError, .noBuiltProduct(scheme: "Sample"))
        }
        // Nothing is installed when there is nothing to install.
        XCTAssertFalse(runner.commands.contains { $0.arguments.contains("install") })
    }

    func testFailedBuildReportsItsErrorsOnceAndStops() async throws {
        let runner = runner(build: Fixtures.failingBuildOutput, exit: 65)
        do {
            _ = try await events(runner, request())
            XCTFail("expected a failure")
        } catch let error as BuildDeskError {
            guard case .buildFailed(let errors, _) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(errors.map(\.message), [
                "cannot find 'missing' in scope",
                "No profiles for 'com.example.sample' were found",
            ])
            XCTAssertEqual(errors.first?.line, 12)
        }
        // Nothing is installed after a failed build.
        XCTAssertEqual(runner.commands.count, 1)
    }

    func testFailedInstallNamesTheStepAndTheReason() async throws {
        let runner = runner()
        runner.onRun = { command in
            if command.arguments.contains("install") {
                return ToolResult(exitCode: 1, stderr: Data("The device is locked.".utf8))
            }
            return ToolResult(exitCode: 0, stdout: Data(Fixtures.buildSettings.utf8))
        }
        do {
            _ = try await events(runner, request())
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? BuildDeskError, .stepFailed(step: .install, message: "The device is locked."))
        }
    }

    func testFullBuildOutputIsKeptInALogFile() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        var summary: RunSummary?
        let pipeline = BuildPipeline(toolRunner: runner(), logDirectory: folder.url, fileExists: { _ in true })
        for try await event in pipeline.run(try request()) {
            if case .finished(let finished) = event { summary = finished }
        }
        let log = try XCTUnwrap(summary?.logFile)
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").map(String.init), Fixtures.buildOutput)
    }
}

final class RunLogTests: XCTestCase {
    func testOldLogsAreRemovedBeyondTheKeptCount() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let kept = BuildDeskConstants.Logs.keptRuns
        for index in 0..<(kept + 5) {
            try folder.write("old", to: String(format: "20260101-0000%02d-Sample.log", index))
        }
        try folder.write("keep me", to: "notes.txt")

        let log = try RunLog(directory: folder.url, scheme: "My App/Dev", date: Date(timeIntervalSince1970: 1_800_000_000))
        await log.append("line")
        await log.close()

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
        XCTAssertEqual(names.filter { $0.hasSuffix(".log") }.count, kept)
        XCTAssertTrue(names.contains("notes.txt"))
        // The oldest went first, and the scheme name is safe as a file name.
        XCTAssertFalse(names.contains("20260101-000000-Sample.log"))
        XCTAssertTrue(log.url.lastPathComponent.hasSuffix("-My-App-Dev.log"))
        XCTAssertEqual(try String(contentsOf: log.url, encoding: .utf8), "line\n")
    }
}

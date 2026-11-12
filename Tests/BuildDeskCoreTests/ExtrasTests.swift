@testable import BuildDeskCore
import XCTest

final class MultiDeviceTests: XCTestCase {
    private let second = Device(
        id: "00008000-0000000000000009", name: "Second iPhone", model: "iPhone 16", platform: "iOS", osVersion: "27.0",
        kind: .physical, connection: .network, isReady: true, isBooted: true
    )

    /// A runner whose installs fail on the given devices.
    private func runner(failingInstallsOn failing: [String] = []) -> FakeToolRunner {
        let runner = FakeToolRunner()
        runner.onStream = { _ in [.exit(0)] }
        runner.onRun = { command in
            if command.arguments.contains("-showBuildSettings") {
                return ToolResult(exitCode: 0, stdout: Data(Fixtures.buildSettings.utf8))
            }
            if command.arguments.contains("install"), failing.contains(where: command.arguments.contains) {
                return ToolResult(exitCode: 1, stderr: Data("The device is locked.".utf8))
            }
            return ToolResult(exitCode: 0)
        }
        return runner
    }

    private func outcomes(_ stream: AsyncThrowingStream<PipelineEvent, Error>) async throws -> [DeviceOutcome] {
        var outcomes: [DeviceOutcome] = []
        var summary: RunSummary?
        for try await event in stream {
            if case .deviceFinished(let outcome) = event { outcomes.append(outcome) }
            if case .finished(let finished) = event { summary = finished }
        }
        XCTAssertEqual(summary?.deviceOutcomes, outcomes)
        return outcomes
    }

    private func request() throws -> BuildRequest {
        BuildRequest(container: try Sample.container(), scheme: "Sample", device: Sample.phone, additionalDevices: [second])
    }

    func testTheSameBuildGoesOnEveryDevice() async throws {
        let runner = runner()
        let outcomes = try await outcomes(BuildPipeline(toolRunner: runner, logDirectory: nil).run(request()))

        XCTAssertEqual(outcomes.map(\.device.name), ["Test iPhone", "Second iPhone"])
        XCTAssertTrue(outcomes.allSatisfy(\.succeeded))
        // One build, then install on both, then launch on both.
        let steps = runner.commands.dropFirst(2).map { $0.arguments.contains("install") ? "install" : "launch" }
        XCTAssertEqual(steps, ["install", "install", "launch", "launch"])
    }

    func testOneFailingDeviceDoesNotStopTheOthers() async throws {
        let runner = runner(failingInstallsOn: [Sample.phoneID])
        let outcomes = try await outcomes(BuildPipeline(toolRunner: runner, logDirectory: nil).run(request()))

        XCTAssertEqual(outcomes, [
            DeviceOutcome(device: Sample.phone, failure: "The device is locked."),
            DeviceOutcome(device: second),
        ])
        // The app is not launched where it was not installed.
        let launches = runner.commands.filter { $0.arguments.contains("launch") }
        XCTAssertEqual(launches.count, 1)
        XCTAssertTrue(launches[0].arguments.contains(second.id))
    }

    func testEveryDeviceFailingFailsTheRun() async throws {
        let runner = runner(failingInstallsOn: [Sample.phoneID, second.id])
        do {
            _ = try await outcomes(BuildPipeline(toolRunner: runner, logDirectory: nil).run(request()))
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? BuildDeskError, .stepFailed(step: .install, message: "The device is locked."))
        }
    }

    func testAnAppFileIsInstalledWithoutBuilding() async throws {
        let runner = runner()
        let artifact = AppArtifact(
            url: URL(fileURLWithPath: "/downloads/Sample.ipa"), bundleIdentifier: "com.example.sample",
            name: "Sample", version: "2.1", platform: .iOS, isSimulatorBuild: false
        )
        let request = InstallRequest(artifact: artifact, devices: [Sample.phone], launches: false)
        let outcomes = try await outcomes(BuildPipeline(toolRunner: runner, logDirectory: nil).install(request))

        XCTAssertEqual(outcomes, [DeviceOutcome(device: Sample.phone)])
        XCTAssertEqual(runner.commands.map(\.text), [
            "xcrun devicectl device install app --device \(Sample.phoneID) /downloads/Sample.ipa",
        ])
        XCTAssertTrue(artifact.fits(Sample.phone))
        XCTAssertFalse(artifact.fits(Sample.simulator))
    }
}

final class ArtifactReaderTests: XCTestCase {
    private func infoPlist(platform: String, name: String = "Sample Shop") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
          <key>CFBundleIdentifier</key><string>com.example.sample</string>
          <key>CFBundleDisplayName</key><string>\(name)</string>
          <key>CFBundleShortVersionString</key><string>2.1</string>
          <key>DTPlatformName</key><string>\(platform)</string>
        </dict></plist>
        """
    }

    func testAnAppFolderIsReadFromItsInfoPlist() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.write(infoPlist(platform: "iphonesimulator"), to: "Sample.app/Info.plist")

        let artifact = try await ArtifactReader(toolRunner: FakeToolRunner()).read(folder.url.appendingPathComponent("Sample.app"))

        XCTAssertEqual(artifact.bundleIdentifier, "com.example.sample")
        XCTAssertEqual(artifact.name, "Sample Shop")
        XCTAssertEqual(artifact.version, "2.1")
        XCTAssertEqual(artifact.platform, .iOS)
        XCTAssertTrue(artifact.isSimulatorBuild)
        XCTAssertTrue(artifact.fits(Sample.simulator))
        XCTAssertFalse(artifact.fits(Sample.phone))
    }

    func testAnArchiveIsReadFromItsMainAppOnly() async throws {
        let runner = FakeToolRunner()
        let plist = infoPlist(platform: "iphoneos")
        runner.onRun = { command in
            if command.arguments.first == "-Z1" {
                // A watch app nested in the main app has an Info.plist of its own.
                let names = ["Payload/", "Payload/Sample.app/Watch/Sample.app/Info.plist", "Payload/Sample.app/Info.plist"]
                return ToolResult(exitCode: 0, stdout: Data(names.joined(separator: "\n").utf8))
            }
            XCTAssertEqual(command.arguments.last, "Payload/Sample.app/Info.plist")
            return ToolResult(exitCode: 0, stdout: Data(plist.utf8))
        }

        let artifact = try await ArtifactReader(toolRunner: runner).read(URL(fileURLWithPath: "/downloads/Sample.IPA"))

        XCTAssertFalse(artifact.isSimulatorBuild)
        XCTAssertEqual(artifact.bundleIdentifier, "com.example.sample")
        XCTAssertEqual(runner.commands.count, 2)
    }

    func testWhatIsNotAnAppIsRefusedWithAReason() async {
        func reason(_ url: URL, _ runner: FakeToolRunner = FakeToolRunner()) async -> String? {
            do {
                _ = try await ArtifactReader(toolRunner: runner).read(url)
                return nil
            } catch {
                guard case BuildDeskError.unreadableArtifact(_, let reason) = error else { return "wrong error" }
                return reason
            }
        }
        let emptyArchive = FakeToolRunner()
        emptyArchive.onRun = { _ in ToolResult(exitCode: 0, stdout: Data("README.txt".utf8)) }

        let missing = await reason(URL(fileURLWithPath: "/nowhere/Sample.app"))
        let archive = await reason(URL(fileURLWithPath: "/downloads/Notes.ipa"), emptyArchive)
        let other = await reason(URL(fileURLWithPath: "/downloads/Sample.zip"))
        XCTAssertEqual(missing, "it has no Info.plist")
        XCTAssertEqual(archive, "it contains no app")
        XCTAssertEqual(other, "it is not a .app or .ipa")
        XCTAssertTrue(ArtifactReader.isArtifact(URL(fileURLWithPath: "/a/B.IPA")))
        XCTAssertFalse(ArtifactReader.isArtifact(URL(fileURLWithPath: "/a/B.xcodeproj")))
    }
}

final class DeviceAppServiceTests: XCTestCase {
    func testConsoleDeliversWhatTheAppPrints() async throws {
        let runner = FakeToolRunner()
        runner.onStream = { _ in [.line("launched"), .line("hello"), .exit(0)] }
        var lines: [String] = []
        for try await line in DeviceAppService(toolRunner: runner).console(bundleIdentifier: "com.example.sample", on: Sample.phone) {
            lines.append(line)
        }
        XCTAssertEqual(lines, ["launched", "hello"])
        XCTAssertEqual(runner.commands.map(\.text), [
            "xcrun devicectl device process launch --device \(Sample.phoneID) --terminate-existing --console com.example.sample",
        ])
    }

    func testConsoleThatCannotStartSaysWhy() async {
        let runner = FakeToolRunner()
        runner.onStream = { _ in [.line("ERROR: The app is not installed."), .exit(1)] }
        do {
            for try await _ in DeviceAppService(toolRunner: runner).console(bundleIdentifier: "com.example.x", on: Sample.simulator) {}
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(
                error as? BuildDeskError,
                .toolFailed(tool: "xcrun simctl", exitCode: 1, message: "ERROR: The app is not installed.")
            )
        }
        XCTAssertEqual(runner.commands.first?.arguments.prefix(3), ["simctl", "launch", "--console"])
    }

    func testUninstallUsesTheToolForTheKindOfDevice() async throws {
        let runner = FakeToolRunner()
        let service = DeviceAppService(toolRunner: runner)
        try await service.uninstall(bundleIdentifier: "com.example.sample", from: Sample.phone)
        try await service.uninstall(bundleIdentifier: "com.example.sample", from: Sample.simulator)

        XCTAssertEqual(runner.commands.map(\.text), [
            "xcrun devicectl device uninstall app --device \(Sample.phoneID) com.example.sample",
            "xcrun simctl uninstall \(Sample.simulatorID) com.example.sample",
        ])

        runner.onRun = { _ in ToolResult(exitCode: 1, stderr: Data("not installed".utf8)) }
        do {
            try await service.uninstall(bundleIdentifier: "com.example.sample", from: Sample.phone)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? BuildDeskError, .toolFailed(tool: "xcrun devicectl", exitCode: 1, message: "not installed"))
        }
    }
}

final class SourceStateTests: XCTestCase {
    private func runner(changes: String = "", isCheckout: Bool = true) -> FakeToolRunner {
        let runner = FakeToolRunner()
        runner.onRun = { command in
            guard isCheckout else { return ToolResult(exitCode: 128, stderr: Data("fatal: not a git repository".utf8)) }
            let output = switch command.arguments.dropFirst(2).first {
            case "status": changes
            default: command.arguments.contains("--short") ? "1a2b3c4\n" : "feature/checkout\n"
            }
            return ToolResult(exitCode: 0, stdout: Data(output.utf8))
        }
        return runner
    }

    func testBranchCommitAndLocalChangesAreRead() async {
        let folder = URL(fileURLWithPath: "/projects/Sample")
        let clean = await SourceStateReader(toolRunner: runner()).state(of: folder)
        XCTAssertEqual(clean, SourceState(branch: "feature/checkout", commit: "1a2b3c4", hasLocalChanges: false))

        let runner = runner(changes: " M Sources/Home.swift\n")
        let changed = await SourceStateReader(toolRunner: runner).state(of: folder)
        XCTAssertEqual(changed?.hasLocalChanges, true)
        // Read-only commands, run in the project's folder.
        XCTAssertEqual(runner.commands.map(\.text), [
            "git -C /projects/Sample rev-parse --abbrev-ref HEAD",
            "git -C /projects/Sample rev-parse --short HEAD",
            "git -C /projects/Sample status --porcelain --untracked-files=no",
        ])
    }

    func testAFolderOutsideACheckoutHasNoState() async {
        let state = await SourceStateReader(toolRunner: runner(isCheckout: false)).state(of: URL(fileURLWithPath: "/tmp"))
        XCTAssertNil(state)
    }
}

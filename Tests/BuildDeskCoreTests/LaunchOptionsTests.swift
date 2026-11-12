@testable import BuildDeskCore
import XCTest

final class LaunchOptionsTests: XCTestCase {
    func testTextIsSplitLikeAShellDoes() throws {
        XCTAssertEqual(try LaunchOptions.words(in: "  -flag   value "), ["-flag", "value"])
        XCTAssertEqual(try LaunchOptions.words(in: #"-name "Test User" 'it''s' a\ b"#), ["-name", "Test User", "its", "a b"])
        // Empty quotes are an empty argument, not nothing.
        XCTAssertEqual(try LaunchOptions.words(in: #"-value """#), ["-value", ""])
        XCTAssertEqual(try LaunchOptions.words(in: ""), [])
        XCTAssertThrowsError(try LaunchOptions.words(in: #"-name "Test"#)) { error in
            XCTAssertEqual(error as? LaunchOptions.ParseError, .init(message: "A quote is opened but never closed."))
        }
    }

    func testTheThreeFieldsBecomeOptions() throws {
        let options = try LaunchOptions.parse(
            arguments: "-skipOnboarding -level 3", environment: #"API_HOST=staging.example.com NOTE="a b=c""#, url: " sample://cart "
        )
        XCTAssertEqual(options.arguments, ["-skipOnboarding", "-level", "3"])
        // Only the first "=" separates the name from the value.
        XCTAssertEqual(options.environment, ["API_HOST": "staging.example.com", "NOTE": "a b=c"])
        XCTAssertEqual(options.url, "sample://cart")
        XCTAssertFalse(options.isEmpty)
        XCTAssertTrue(try LaunchOptions.parse(arguments: "", environment: " ", url: "").isEmpty)
    }

    func testMistakesAreExplained() {
        func message(arguments: String = "", environment: String = "", url: String = "") -> String? {
            do {
                _ = try LaunchOptions.parse(arguments: arguments, environment: environment, url: url)
                return nil
            } catch {
                return (error as? LaunchOptions.ParseError)?.message
            }
        }
        XCTAssertEqual(message(environment: "DEBUG"), "\"DEBUG\" is not a variable. Write each one as NAME=value.")
        XCTAssertEqual(message(environment: "=1"), "\"=1\" is not a variable. Write each one as NAME=value.")
        XCTAssertEqual(
            message(url: "cart"), "\"cart\" is not a link. It needs a scheme, as in myapp://home or https://example.com."
        )
    }

    func testOptionsWrittenBackAsTextReadTheSame() throws {
        let options = LaunchOptions(
            arguments: ["-name", "Test User", "", #"say "hi""#, #"back\slash"#],
            environment: ["B": "two words", "A": "1"],
            url: "sample://home"
        )
        XCTAssertEqual(options.environmentText, #"A=1 "B=two words""#)
        let reread = try LaunchOptions.parse(
            arguments: options.argumentsText, environment: options.environmentText, url: options.url ?? ""
        )
        XCTAssertEqual(reread, options)
    }

    func testDeviceLaunchCarriesEverythingInOneCommand() {
        let options = LaunchOptions(arguments: ["-level", "3"], environment: ["B": "2", "A": "1"], url: "sample://cart")

        let launch = AppleTools.launchOnDevice(udid: Sample.phoneID, bundleIdentifier: "com.example.sample", options: options)
        XCTAssertEqual(launch.arguments, [
            "devicectl", "device", "process", "launch", "--device", Sample.phoneID, "--terminate-existing",
            "--environment-variables", #"{"A":"1","B":"2"}"#,
            "--payload-url", "sample://cart",
            "com.example.sample", "--", "-level", "3",
        ])
        // The console is the same launch, attached.
        let console = AppleTools.consoleOnDevice(udid: Sample.phoneID, bundleIdentifier: "com.example.sample", options: options)
        XCTAssertEqual(console.arguments[7], "--console")
        XCTAssertEqual(console.arguments.suffix(3), ["--", "-level", "3"])
        // Without options the command is what it always was.
        let plain = AppleTools.launchOnDevice(udid: Sample.phoneID, bundleIdentifier: "com.example.sample")
        XCTAssertEqual(plain.arguments.last, "com.example.sample")
    }

    func testSimulatorLaunchPassesVariablesThroughTheToolsEnvironment() {
        let options = LaunchOptions(arguments: ["-level", "3"], environment: ["API_HOST": "staging.example.com"])
        let command = AppleTools.launchOnSimulator(udid: Sample.simulatorID, bundleIdentifier: "com.example.sample", options: options)

        XCTAssertEqual(command.arguments, [
            "simctl", "launch", "--terminate-running-process", Sample.simulatorID, "com.example.sample", "-level", "3",
        ])
        XCTAssertEqual(command.environment, ["SIMCTL_CHILD_API_HOST": "staging.example.com"])
    }

    func testPipelineLaunchesWithTheOptionsAndOpensTheLinkOnASimulator() async throws {
        let runner = FakeToolRunner()
        runner.onRun = { command in
            command.arguments.contains("-showBuildSettings")
                ? ToolResult(exitCode: 0, stdout: Data(Fixtures.buildSettings.utf8)) : ToolResult(exitCode: 0)
        }
        let options = LaunchOptions(arguments: ["-skipOnboarding"], url: "sample://cart")
        for device in [Sample.phone, Sample.simulator] {
            let request = BuildRequest(container: try Sample.container(), scheme: "Sample", device: device, launchOptions: options)
            for try await _ in BuildPipeline(toolRunner: runner, logDirectory: nil).run(request) {}
        }
        let launches = runner.commands.map(\.text).filter { $0.contains(" launch ") || $0.contains("openurl") }

        XCTAssertEqual(launches, [
            "xcrun devicectl device process launch --device \(Sample.phoneID) --terminate-existing --payload-url sample://cart "
                + "com.example.sample -- -skipOnboarding",
            "xcrun simctl launch --terminate-running-process \(Sample.simulatorID) com.example.sample -skipOnboarding",
            "xcrun simctl openurl \(Sample.simulatorID) sample://cart",
        ])
    }

    func testAToolGetsItsExtraEnvironment() async throws {
        let command = ToolCommand(executable: "/bin/sh", arguments: ["-c", "printf '%s' \"$BUILDDESK_TEST_VALUE-$HOME\""],
                                  environment: ["BUILDDESK_TEST_VALUE": "added"])
        let result = try await ProcessToolRunner().run(command)
        let output = String(decoding: result.stdout, as: UTF8.self)

        // The added variable is there, and so is what the process already had.
        XCTAssertTrue(output.hasPrefix("added-/"))
    }
}

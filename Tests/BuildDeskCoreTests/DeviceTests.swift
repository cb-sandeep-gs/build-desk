@testable import BuildDeskCore
import XCTest

final class DeviceParserTests: XCTestCase {
    func testDeviceListGivesRealDevicesOnly() throws {
        let devices = try DeviceCtlParser.parse(Data(Fixtures.deviceList.utf8))

        XCTAssertEqual(devices.map(\.name), ["Test iPhone", "Old iPhone", "Test iPad"])
        XCTAssertEqual(devices[0], Sample.phone)
    }

    func testRememberedDeviceIsNotReady() throws {
        let old = try XCTUnwrap(DeviceCtlParser.parse(Data(Fixtures.deviceList.utf8)).first { $0.name == "Old iPhone" })

        XCTAssertFalse(old.isReady)
        XCTAssertEqual(old.connection, .none)
        XCTAssertFalse(old.isBooted)
        XCTAssertEqual(old.osVersion, "26.1")
    }

    func testDeviceDescribedOnlyByTheNewerDictionary() throws {
        let pad = try XCTUnwrap(DeviceCtlParser.parse(Data(Fixtures.deviceList.utf8)).first { $0.name == "Test iPad" })

        XCTAssertEqual(pad.id, "00008000-0000000000000003")
        XCTAssertEqual(pad.model, "iPad Pro")
        XCTAssertEqual(pad.osVersion, "27.0")
        XCTAssertEqual(pad.connection, .network)
        XCTAssertTrue(pad.isReady)
    }

    func testSimulatorListSkipsUnavailableRuntimes() throws {
        let simulators = try SimctlParser.parse(Data(Fixtures.simulatorList.utf8)).sorted { $0.name < $1.name }

        XCTAssertEqual(simulators.map(\.name), ["iPad Pro 11-inch", "iPhone 17 Pro"])
        XCTAssertEqual(simulators.map(\.isBooted), [true, false])
        XCTAssertEqual(simulators[1], Sample.simulator)
    }

    func testUnexpectedOutputIsReportedAsSuch() {
        for parse in [DeviceCtlParser.parse, SimctlParser.parse] {
            XCTAssertThrowsError(try parse(Data("{\"unexpected\":true}".utf8))) { error in
                guard case BuildDeskError.unexpectedOutput = error else { return XCTFail("wrong error: \(error)") }
            }
        }
    }
}

final class DeviceDiscoveryTests: XCTestCase {
    /// Answers like the real tools: devicectl writes its JSON to the file it is given.
    private func runner(devicectlFails: Bool = false, simctlFails: Bool = false) -> FakeToolRunner {
        let runner = FakeToolRunner()
        runner.onRun = { command in
            if command.arguments.first == "devicectl" {
                guard !devicectlFails else { return ToolResult(exitCode: 1, stderr: Data("no CoreDevice".utf8)) }
                let path = try XCTUnwrap(command.arguments.last)
                try Data(Fixtures.deviceList.utf8).write(to: URL(fileURLWithPath: path))
                return ToolResult(exitCode: 0)
            }
            guard !simctlFails else { return ToolResult(exitCode: 1, stderr: Data("no simulators".utf8)) }
            return ToolResult(exitCode: 0, stdout: Data(Fixtures.simulatorList.utf8))
        }
        return runner
    }

    func testDevicesAreOrderedUsableFirst() async throws {
        let devices = try await DeviceDiscovery(toolRunner: runner()).devices()

        XCTAssertEqual(devices.map(\.name), [
            "Test iPad", "Test iPhone",   // real and reachable
            "iPad Pro 11-inch",           // booted simulator
            "Old iPhone",                 // real but not connected
            "iPhone 17 Pro",              // simulator that is shut down
        ])
    }

    func testOneFailingToolDoesNotHideTheOther() async throws {
        let withoutSimulators = try await DeviceDiscovery(toolRunner: runner(simctlFails: true)).devices()
        XCTAssertEqual(withoutSimulators.map(\.kind), [.physical, .physical, .physical])

        let withoutDevices = try await DeviceDiscovery(toolRunner: runner(devicectlFails: true)).devices()
        XCTAssertEqual(withoutDevices.map(\.kind), [.simulator, .simulator])
    }

    func testBothToolsFailingIsAnError() async {
        do {
            _ = try await DeviceDiscovery(toolRunner: runner(devicectlFails: true, simctlFails: true)).devices()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? BuildDeskError, .toolFailed(tool: "xcrun devicectl", exitCode: 1, message: "no CoreDevice"))
        }
    }

    func testDeviceIsFoundByIdentifierOrName() async throws {
        let discovery = DeviceDiscovery(toolRunner: runner())

        let byID = try await discovery.device(matching: Sample.phoneID)
        XCTAssertEqual(byID.name, "Test iPhone")
        let byName = try await discovery.device(matching: "iPhone 17 Pro")
        XCTAssertEqual(byName.id, Sample.simulatorID)
        do {
            _ = try await discovery.device(matching: "Nobody's phone")
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? BuildDeskError, .deviceNotFound(query: "Nobody's phone"))
        }
    }
}

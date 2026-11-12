import Foundation

/// Finds the devices and simulators an app can be installed on.
public struct DeviceDiscovery: Sendable {
    private let toolRunner: any ToolRunning

    public init(toolRunner: any ToolRunning = ProcessToolRunner()) {
        self.toolRunner = toolRunner
    }

    /// Real devices first (reachable ones at the top), then simulators (booted ones at the top).
    /// A failure to list simulators does not hide real devices, and the reverse.
    public func devices() async throws -> [Device] {
        async let physical = result { try await physicalDevices() }
        async let simulated = result { try await simulators() }
        let (physicalResult, simulatedResult) = await (physical, simulated)

        // Only when both tools fail is there nothing useful to show.
        if case .failure(let error) = physicalResult, case .failure = simulatedResult { throw error }
        let found = ((try? physicalResult.get()) ?? []) + ((try? simulatedResult.get()) ?? [])
        return found.sorted(by: Self.listOrder)
    }

    /// Looks a device up by UDID or by exact name, for the command line and saved pairs.
    public func device(matching query: String) async throws -> Device {
        let all = try await devices()
        guard let match = all.first(where: { $0.id == query }) ?? all.first(where: { $0.name == query }) else {
            throw BuildDeskError.deviceNotFound(query: query)
        }
        return match
    }

    private func physicalDevices() async throws -> [Device] {
        // devicectl writes JSON only to a file; its standard output is a table for people.
        let jsonURL = FileManager.default.temporaryDirectory.appendingPathComponent("builddesk-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }
        let command = AppleTools.listDevices(jsonOutput: jsonURL)
        let result = try await toolRunner.run(command)
        guard result.succeeded, let data = try? Data(contentsOf: jsonURL) else {
            throw BuildDeskError.toolFailed(tool: command.displayName, exitCode: result.exitCode, message: result.failureTail())
        }
        return try DeviceCtlParser.parse(data)
    }

    private func simulators() async throws -> [Device] {
        let command = AppleTools.listSimulators()
        let result = try await toolRunner.run(command)
        guard result.succeeded else {
            throw BuildDeskError.toolFailed(tool: command.displayName, exitCode: result.exitCode, message: result.failureTail())
        }
        return try SimctlParser.parse(result.stdout)
    }

    private func result<T: Sendable>(_ work: @Sendable () async throws -> T) async -> Result<T, Error> {
        do {
            return .success(try await work())
        } catch {
            return .failure(error)
        }
    }

    private static func listOrder(_ lhs: Device, _ rhs: Device) -> Bool {
        // Lower rank sorts first: usable-now before the rest, real devices before simulators.
        func rank(_ device: Device) -> Int {
            switch (device.kind, device.kind == .physical ? device.isReady : device.isBooted) {
            case (.physical, true): 0
            case (.simulator, true): 1
            case (.physical, false): 2
            case (.simulator, false): 3
            }
        }
        let (left, right) = (rank(lhs), rank(rhs))
        if left != right { return left < right }
        if lhs.name != rhs.name { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
        // Same name on several OS versions: newest first.
        return lhs.osVersion.compare(rhs.osVersion, options: .numeric) == .orderedDescending
    }
}

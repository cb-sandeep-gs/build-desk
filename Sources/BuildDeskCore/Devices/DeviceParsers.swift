import Foundation

/// Reads the JSON written by `devicectl list devices --json-output`.
///
/// devicectl reports each device twice: in three older dictionaries it marks as deprecated, and in a
/// newer `properties` dictionary. Both are read, newer first, so Build Desk works across Xcode
/// versions on either side of the change.
enum DeviceCtlParser {
    private enum Value {
        static let physical = "physical"
        static let wired = "wired"
        static let unavailable = "unavailable"
        static let booted = "booted"
    }

    /// Returns real devices only. devicectl also lists simulators in newer Xcode versions, but
    /// `simctl` is the tool that installs on them, so they come from `SimctlParser`.
    static func parse(_ data: Data) throws -> [Device] {
        let payload: DeviceCtlPayload
        do {
            payload = try JSONDecoder().decode(DeviceCtlPayload.self, from: data)
        } catch {
            throw BuildDeskError.unexpectedOutput(tool: "devicectl", reason: error.localizedDescription)
        }
        return payload.result.devices.compactMap(device(from:))
    }

    private static func device(from entry: DeviceCtlEntry) -> Device? {
        let hardware = entry.properties?.hardware ?? entry.hardwareProperties
        guard let hardware, hardware.reality == Value.physical, let udid = hardware.udid else { return nil }

        let transport = entry.properties?.connection?.transportType ?? entry.connectionProperties?.transportType
        let linkState = entry.properties?.connection?.state ?? entry.connectionProperties?.tunnelState
        let bootState = entry.properties?.state?.bootState ?? entry.deviceProperties?.bootState
        let connection: Device.Connection = switch transport {
        case .none: .none
        case Value.wired: .wired
        default: .network
        }
        return Device(
            id: udid,
            name: entry.properties?.state?.name ?? entry.deviceProperties?.name ?? udid,
            model: hardware.marketingName ?? hardware.productType ?? "",
            platform: hardware.platform ?? "",
            osVersion: entry.properties?.software?.osVersionNumber?.stringValue ?? entry.deviceProperties?.osVersionNumber ?? "",
            kind: .physical,
            connection: connection,
            // A device this Mac only remembers has no transport and an unavailable link.
            isReady: connection != .none && linkState != Value.unavailable,
            isBooted: bootState == Value.booted
        )
    }
}

private struct DeviceCtlPayload: Decodable {
    struct Result: Decodable {
        let devices: [DeviceCtlEntry]
    }

    let result: Result
}

private struct DeviceCtlEntry: Decodable {
    let hardwareProperties: DeviceCtlHardware?
    let deviceProperties: DeviceCtlLegacyDevice?
    let connectionProperties: DeviceCtlLegacyConnection?
    let properties: DeviceCtlProperties?
}

/// Same shape in the older and newer dictionaries.
private struct DeviceCtlHardware: Decodable {
    let udid: String?
    let marketingName: String?
    let productType: String?
    let platform: String?
    let reality: String?
}

private struct DeviceCtlLegacyDevice: Decodable {
    let name: String?
    let osVersionNumber: String?
    let bootState: String?
}

private struct DeviceCtlLegacyConnection: Decodable {
    let transportType: String?
    let tunnelState: String?
}

private struct DeviceCtlProperties: Decodable {
    struct Connection: Decodable {
        let transportType: String?
        let state: String?
    }

    struct Software: Decodable {
        let osVersionNumber: Version?
    }

    struct Version: Decodable {
        let stringValue: String?
    }

    struct State: Decodable {
        let name: String?
        let bootState: String?
    }

    let hardware: DeviceCtlHardware?
    let connection: Connection?
    let software: Software?
    let state: State?
}

/// Reads `simctl list devices --json`.
enum SimctlParser {
    private static let runtimePrefix = "com.apple.CoreSimulator.SimRuntime."
    private static let bootedState = "Booted"

    private struct Payload: Decodable {
        let devices: [String: [Entry]]
    }

    private struct Entry: Decodable {
        let udid: String
        let name: String
        let state: String?
        let isAvailable: Bool?
    }

    /// Returns simulators whose runtime is installed; the others cannot be booted.
    static func parse(_ data: Data) throws -> [Device] {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw BuildDeskError.unexpectedOutput(tool: "simctl", reason: error.localizedDescription)
        }
        return payload.devices.flatMap { runtime, entries -> [Device] in
            let (platform, version) = platformAndVersion(fromRuntime: runtime)
            return entries.filter { $0.isAvailable == true }.map { entry in
                Device(
                    id: entry.udid,
                    name: entry.name,
                    model: entry.name,
                    platform: platform,
                    osVersion: version,
                    kind: .simulator,
                    connection: .local,
                    isReady: true,
                    isBooted: entry.state == bootedState
                )
            }
        }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-27-2" → ("iOS", "27.2").
    private static func platformAndVersion(fromRuntime runtime: String) -> (platform: String, version: String) {
        let parts = runtime.replacingOccurrences(of: runtimePrefix, with: "").split(separator: "-")
        guard let platform = parts.first else { return ("", "") }
        return (String(platform), parts.dropFirst().joined(separator: "."))
    }
}

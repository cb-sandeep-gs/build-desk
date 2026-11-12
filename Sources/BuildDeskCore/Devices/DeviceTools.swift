import Foundation

/// A crash report on a device or simulator.
public struct CrashLog: Sendable, Equatable, Identifiable {
    /// The file name, such as "Sample-2026-01-01-101500.ips".
    public let name: String
    public let date: Date?
    public let bytes: Int64?

    public var id: String { name }

    public init(name: String, date: Date? = nil, bytes: Int64? = nil) {
        self.name = name
        self.date = date
        self.bytes = bytes
    }
}

/// Things to fetch from a device: a picture of its screen, an app's data and crash reports.
public protocol DeviceToolsProviding: Sendable {
    /// Saves a picture of the device's screen as a PNG.
    func screenshot(of device: Device, to file: URL) async throws
    /// Copies an installed app's data folder (documents, preferences, caches) into `folder`.
    func copyAppData(bundleIdentifier: String, from device: Device, to folder: URL) async throws
    /// Crash reports whose name starts with `processName`, newest first.
    func crashLogs(forProcess processName: String, on device: Device) async throws -> [CrashLog]
    /// Copies the given crash reports into `folder`.
    func copy(_ logs: [CrashLog], from device: Device, to folder: URL) async throws
}

public struct DeviceToolsService: DeviceToolsProviding {
    private enum Domain {
        static let appData = "appDataContainer"
        static let crashLogs = "systemCrashLogs"
    }

    /// Crash reports end in one of these; the folder also holds analytics and other system logs.
    private static let crashExtensions: Set<String> = ["ips", "crash"]
    private static let simulatorReports = "Library/Logs/DiagnosticReports"

    private let toolRunner: any ToolRunning
    private let simulatorReportsFolder: URL

    /// - Parameter simulatorReportsFolder: where macOS keeps crash reports of simulator apps; nil
    ///   uses the user's `~/Library/Logs/DiagnosticReports`.
    public init(toolRunner: any ToolRunning = ProcessToolRunner(), simulatorReportsFolder: URL? = nil) {
        self.toolRunner = toolRunner
        self.simulatorReportsFolder = simulatorReportsFolder
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(Self.simulatorReports)
    }

    public func screenshot(of device: Device, to file: URL) async throws {
        let command = switch device.kind {
        case .physical: AppleTools.screenshotOfDevice(udid: device.id, to: file)
        case .simulator: AppleTools.screenshotOfSimulator(udid: device.id, to: file)
        }
        try await runChecked(command)
    }

    public func copyAppData(bundleIdentifier: String, from device: Device, to folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        switch device.kind {
        case .physical:
            // "." is the whole container.
            try await runChecked(AppleTools.copyFromDevice(
                udid: device.id, domain: Domain.appData, identifier: bundleIdentifier, source: ".", to: folder
            ))
        case .simulator:
            // A simulator's files are on this Mac; ask where, then copy.
            let result = try await runChecked(AppleTools.appDataFolderOnSimulator(udid: device.id, bundleIdentifier: bundleIdentifier))
            let path = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let source = URL(fileURLWithPath: path)
            for item in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try FileManager.default.copyItem(at: item, to: folder.appendingPathComponent(item.lastPathComponent))
            }
        }
    }

    public func crashLogs(forProcess processName: String, on device: Device) async throws -> [CrashLog] {
        let all: [CrashLog]
        switch device.kind {
        case .physical:
            let jsonURL = FileManager.default.temporaryDirectory.appendingPathComponent("builddesk-files-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: jsonURL) }
            try await runChecked(AppleTools.listFilesOnDevice(udid: device.id, domain: Domain.crashLogs, jsonOutput: jsonURL))
            all = try DeviceFilesParser.parse(Data(contentsOf: jsonURL))
        case .simulator:
            all = ((try? FileManager.default.contentsOfDirectory(
                at: simulatorReportsFolder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
            )) ?? []).map { url in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                return CrashLog(name: url.lastPathComponent, date: values?.contentModificationDate, bytes: values?.fileSize.map(Int64.init))
            }
        }
        // "Sample-2026-…": the process name, then a dash. "SampleKit-…" is another process.
        let prefix = "\(processName)-"
        return all
            .filter { $0.name.hasPrefix(prefix) && Self.crashExtensions.contains(URL(fileURLWithPath: $0.name).pathExtension) }
            .sorted { ($0.date ?? .distantPast, $0.name) > ($1.date ?? .distantPast, $1.name) }
    }

    public func copy(_ logs: [CrashLog], from device: Device, to folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for log in logs {
            let destination = folder.appendingPathComponent(log.name)
            switch device.kind {
            case .physical:
                try await runChecked(AppleTools.copyFromDevice(
                    udid: device.id, domain: Domain.crashLogs, identifier: nil, source: log.name, to: destination
                ))
            case .simulator:
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: simulatorReportsFolder.appendingPathComponent(log.name), to: destination)
            }
        }
    }

    @discardableResult
    private func runChecked(_ command: ToolCommand) async throws -> ToolResult {
        let result = try await toolRunner.run(command)
        guard result.succeeded else {
            throw BuildDeskError.toolFailed(tool: command.displayName, exitCode: result.exitCode, message: result.failureTail())
        }
        return result
    }
}

/// Reads the JSON written by `devicectl device info files --json-output`.
enum DeviceFilesParser {
    private struct Payload: Decodable {
        let result: Listing
    }

    private struct Listing: Decodable {
        let files: [Entry]
    }

    private struct Entry: Decodable {
        let name: String
        let metadata: Metadata?
        let resources: Resources?
    }

    private struct Metadata: Decodable {
        let lastModDate: String?
        let size: Int64?
    }

    private struct Resources: Decodable {
        let isDirectory: Bool?
    }

    static func parse(_ data: Data) throws -> [CrashLog] {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw BuildDeskError.unexpectedOutput(tool: "devicectl", reason: error.localizedDescription)
        }
        // "2026-01-01T10:15:00.000Z": with fractions of a second.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return payload.result.files
            .filter { $0.resources?.isDirectory != true }
            .map { CrashLog(name: $0.name, date: $0.metadata?.lastModDate.flatMap(formatter.date(from:)), bytes: $0.metadata?.size) }
    }
}

import Foundation

/// Reads a `.app` folder or an `.ipa` file: what app it is and what it can be installed on.
public struct ArtifactReader: Sendable {
    public static let appExtension = "app"
    public static let archiveExtension = "ipa"

    private enum Key {
        static let bundleIdentifier = "CFBundleIdentifier"
        static let displayName = "CFBundleDisplayName"
        static let name = "CFBundleName"
        static let version = "CFBundleShortVersionString"
        static let platformName = "DTPlatformName"
        static let supportedPlatforms = "CFBundleSupportedPlatforms"
    }

    private static let infoPlist = "Info.plist"
    private static let simulatorMarker = "simulator"

    private let toolRunner: any ToolRunning

    public init(toolRunner: any ToolRunning = ProcessToolRunner()) {
        self.toolRunner = toolRunner
    }

    /// True for the two kinds of file this reads; used to tell an app file from a project.
    public static func isArtifact(_ url: URL) -> Bool {
        [appExtension, archiveExtension].contains(url.pathExtension.lowercased())
    }

    public func read(_ url: URL) async throws -> AppArtifact {
        let data: Data
        switch url.pathExtension.lowercased() {
        case Self.appExtension:
            guard let contents = try? Data(contentsOf: url.appendingPathComponent(Self.infoPlist)) else {
                throw BuildDeskError.unreadableArtifact(path: url.path, reason: "it has no Info.plist")
            }
            data = contents
        case Self.archiveExtension:
            data = try await infoPlist(inArchive: url)
        default:
            throw BuildDeskError.unreadableArtifact(path: url.path, reason: "it is not a .app or .ipa")
        }

        guard let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let bundleIdentifier = info[Key.bundleIdentifier] as? String else {
            throw BuildDeskError.unreadableArtifact(path: url.path, reason: "its Info.plist has no bundle identifier")
        }
        // "iphoneos" / "iphonesimulator"; older builds only list "iPhoneOS" / "iPhoneSimulator".
        let platformName = (info[Key.platformName] as? String ?? (info[Key.supportedPlatforms] as? [String])?.first ?? "").lowercased()
        return AppArtifact(
            url: url,
            bundleIdentifier: bundleIdentifier,
            name: info[Key.displayName] as? String ?? info[Key.name] as? String ?? url.deletingPathExtension().lastPathComponent,
            version: info[Key.version] as? String,
            platform: Platform(sdkRoot: platformName),
            isSimulatorBuild: platformName.contains(Self.simulatorMarker)
        )
    }
}

extension ArtifactReader {
    private static let payloadFolder = "Payload"
    /// "Payload/Name.app/Info.plist": the main app's own file, not one of an app nested inside it.
    private static let mainInfoPlistDepth = 3

    /// An .ipa is a zip; read the one file needed instead of unpacking hundreds of megabytes.
    private func infoPlist(inArchive url: URL) async throws -> Data {
        let listing = try await toolRunner.run(AppleTools.listArchive(url))
        let entry = String(decoding: listing.stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first { name in
                let parts = name.split(separator: "/")
                return parts.count == Self.mainInfoPlistDepth && parts[0] == Self.payloadFolder
                    && parts[1].hasSuffix(".\(Self.appExtension)") && parts[2] == Self.infoPlist
            }
        guard listing.succeeded, let entry else {
            throw BuildDeskError.unreadableArtifact(path: url.path, reason: "it contains no app")
        }
        let result = try await toolRunner.run(AppleTools.extract(entry, fromArchive: url))
        guard result.succeeded, !result.stdout.isEmpty else {
            throw BuildDeskError.unreadableArtifact(path: url.path, reason: "its Info.plist can't be read")
        }
        return result.stdout
    }
}

/// Console and uninstall for an app that is on a device.
public struct DeviceAppService: Sendable {
    private let toolRunner: any ToolRunning

    public init(toolRunner: any ToolRunning = ProcessToolRunner()) {
        self.toolRunner = toolRunner
    }

    /// Launches the app attached to its standard output and error. This is what the app prints
    /// (`print`, `NSLog`); unified logging (`os_log`, `Logger`) does not come through here.
    public func console(bundleIdentifier: String, on device: Device) -> AsyncThrowingStream<String, Error> {
        let command = switch device.kind {
        case .physical: AppleTools.consoleOnDevice(udid: device.id, bundleIdentifier: bundleIdentifier)
        case .simulator: AppleTools.consoleOnSimulator(udid: device.id, bundleIdentifier: bundleIdentifier)
        }
        let output = toolRunner.stream(command)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var lastLines: [String] = []
                    for try await event in output {
                        switch event {
                        case .line(let line):
                            continuation.yield(line)
                            lastLines = Array((lastLines + [line]).suffix(BuildDeskConstants.Logs.failureTailLines))
                        case .exit(let code) where code != 0 && !Task.isCancelled:
                            // The tool's last lines say why (app not installed, device locked).
                            throw BuildDeskError.toolFailed(
                                tool: command.displayName, exitCode: code, message: lastLines.joined(separator: "\n")
                            )
                        case .exit:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Stopping the console stops the tool; the app itself keeps running on the device.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func uninstall(bundleIdentifier: String, from device: Device) async throws {
        let command = switch device.kind {
        case .physical: AppleTools.uninstallFromDevice(udid: device.id, bundleIdentifier: bundleIdentifier)
        case .simulator: AppleTools.uninstallFromSimulator(udid: device.id, bundleIdentifier: bundleIdentifier)
        }
        let result = try await toolRunner.run(command)
        guard result.succeeded else {
            throw BuildDeskError.toolFailed(tool: command.displayName, exitCode: result.exitCode, message: result.failureTail())
        }
    }
}

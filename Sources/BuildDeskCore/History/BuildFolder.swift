import Foundation

/// The folder Xcode keeps a project's build output in, and how much disk it takes.
public struct BuildFolder: Sendable, Equatable {
    /// The project's folder inside DerivedData.
    public let url: URL
    /// Size of its `Build` subfolder on disk; nil when it has none (nothing built, or just cleaned).
    public let buildBytes: Int64?

    public init(url: URL, buildBytes: Int64?) {
        self.url = url
        self.buildBytes = buildBytes
    }

    /// The part that holds build products and intermediates. Deleting it frees the space and makes
    /// the next build a full one; package checkouts and the index live beside it and are kept.
    public var buildURL: URL { url.appendingPathComponent(BuildFolderService.buildSubfolder) }
}

/// Finds, measures and cleans a project's build folder.
public protocol BuildFolderManaging: Sendable {
    /// Nil when the project has never been built on this Mac.
    func buildFolder(for container: ProjectContainer) async -> BuildFolder?
    /// Deletes the folder's `Build` subfolder. The caller asks the user first.
    func clean(_ folder: BuildFolder) async throws
    /// Size of the whole folder: build output, package checkouts and the index.
    func totalBytes(of folder: BuildFolder) async -> Int64?
    /// Deletes the whole folder, for a project that itself is being removed. The caller asks the user first.
    func removeAll(_ folder: BuildFolder) async throws
}

public struct BuildFolderService: BuildFolderManaging {
    static let buildSubfolder = "Build"
    private static let infoFile = "info.plist"
    private static let workspacePathKey = "WorkspacePath"
    private static let xcodeDefaults = "com.apple.dt.Xcode"
    private static let customLocationKey = "IDECustomDerivedDataLocation"
    private static let defaultLocation = "Library/Developer/Xcode/DerivedData"
    private let toolRunner: any ToolRunning
    private let derivedDataRoot: URL

    /// - Parameter derivedDataRoot: where Xcode keeps build folders; nil reads Xcode's own setting.
    public init(toolRunner: any ToolRunning = ProcessToolRunner(), derivedDataRoot: URL? = nil) {
        self.toolRunner = toolRunner
        self.derivedDataRoot = derivedDataRoot ?? Self.xcodeDerivedDataRoot()
    }

    /// The location set in Xcode's settings when it is an absolute path, else Xcode's default.
    static func xcodeDerivedDataRoot() -> URL {
        if let custom = UserDefaults(suiteName: xcodeDefaults)?.string(forKey: customLocationKey), custom.hasPrefix("/") {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(defaultLocation)
    }

    public func buildFolder(for container: ProjectContainer) async -> BuildFolder? {
        guard let url = locate(container) else { return nil }
        return BuildFolder(url: url, buildBytes: await size(of: url.appendingPathComponent(Self.buildSubfolder)))
    }

    public func clean(_ folder: BuildFolder) async throws {
        try checkOwned(folder)
        guard FileManager.default.fileExists(atPath: folder.buildURL.path) else { return }
        try FileManager.default.removeItem(at: folder.buildURL)
    }

    public func totalBytes(of folder: BuildFolder) async -> Int64? {
        await size(of: folder.url)
    }

    public func removeAll(_ folder: BuildFolder) async throws {
        try checkOwned(folder)
        guard FileManager.default.fileExists(atPath: folder.url.path) else { return }
        try FileManager.default.removeItem(at: folder.url)
    }

    /// Only ever a folder directly inside the build root, as this service locates them.
    private func checkOwned(_ folder: BuildFolder) throws {
        guard folder.url.deletingLastPathComponent().standardizedFileURL == derivedDataRoot.standardizedFileURL else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    /// Xcode names the folder after the project plus a hash, and records the project's path in an
    /// `info.plist` inside it; matching on that path avoids recomputing the hash.
    private func locate(_ container: ProjectContainer) -> URL? {
        let prefix = "\(container.name)-"
        let candidates = (try? FileManager.default.contentsOfDirectory(at: derivedDataRoot, includingPropertiesForKeys: nil)) ?? []
        return candidates.first { folder in
            guard folder.lastPathComponent.hasPrefix(prefix),
                  let data = try? Data(contentsOf: folder.appendingPathComponent(Self.infoFile)),
                  let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  let path = info[Self.workspacePathKey] as? String else { return false }
            return URL(fileURLWithPath: path).standardizedFileURL == container.url
        }
    }

    private func size(of folder: URL) async -> Int64? {
        await DiskUsage.bytes(of: folder, toolRunner: toolRunner)
    }
}

/// The size of a folder on disk.
enum DiskUsage {
    private static let bytesPerKilobyte: Int64 = 1024

    /// `du` measures hundreds of thousands of files far faster than walking them one by one.
    /// Nil when the folder is not there or could not be measured.
    static func bytes(of folder: URL, toolRunner: any ToolRunning) async -> Int64? {
        guard FileManager.default.fileExists(atPath: folder.path),
              let result = try? await toolRunner.run(AppleTools.diskUsage(of: folder)), result.succeeded else { return nil }
        // "4521984<tab>/path": the first field is the size.
        let firstField = String(decoding: result.stdout, as: UTF8.self).split(whereSeparator: \.isWhitespace).first
        return firstField.flatMap { Int64($0) }.map { $0 * bytesPerKilobyte }
    }
}

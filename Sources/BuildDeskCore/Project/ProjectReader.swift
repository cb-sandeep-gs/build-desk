import Foundation

/// Reads a project's schemes, targets and configurations.
///
/// Two speeds, because `xcodebuild -list` resolves Swift packages first and can take half a minute:
/// `quickSnapshot` reads the project's own files and returns at once, so a scheme list can be drawn
/// immediately; `fullSnapshot` then asks `xcodebuild` and adds the schemes that exist by name only.
public struct ProjectReader: Sendable {
    private typealias Layout = BuildDeskConstants.ProjectLayout

    private let toolRunner: any ToolRunning

    public init(toolRunner: any ToolRunning = ProcessToolRunner()) {
        self.toolRunner = toolRunner
    }

    /// Reads scheme files and `project.pbxproj` only. No tool is run.
    public func quickSnapshot(of container: ProjectContainer) throws -> ProjectSnapshot {
        var schemes = try schemes(in: container.url)
        var targets: [ProjectTarget] = []
        var configurations: [String] = []
        var defaultConfiguration: String?

        for projectURL in try projectURLs(of: container) {
            let file = try projectFile(at: projectURL)
            targets += file.targets
            configurations += file.configurations.filter { !configurations.contains($0) }
            defaultConfiguration = defaultConfiguration ?? file.defaultConfiguration
            // A workspace shows the schemes of its projects as well as its own.
            if container.kind == .workspace {
                schemes += try self.schemes(in: projectURL).filter { scheme in !schemes.contains { $0.name == scheme.name } }
            }
        }
        let loaded = ProjectConfigLoader.load(for: container)
        return ProjectSnapshot(
            container: container,
            schemes: schemes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            targets: targets,
            configurations: configurations,
            defaultConfiguration: defaultConfiguration,
            config: loaded.config,
            configProblem: loaded.problem
        )
    }

    /// The quick snapshot plus every scheme `xcodebuild` reports. Schemes without a scheme file
    /// are added with kind `.other`.
    public func fullSnapshot(of container: ProjectContainer) async throws -> ProjectSnapshot {
        let quick = try quickSnapshot(of: container)
        let command = AppleTools.listProject(container)
        let result = try await toolRunner.run(command)
        guard result.succeeded else {
            throw BuildDeskError.toolFailed(tool: command.displayName, exitCode: result.exitCode, message: result.failureTail())
        }
        let listing = try XcodeListParser.parse(result.stdout)
        let known = Set(quick.schemes.map(\.name))
        let extra = listing.schemes.filter { !known.contains($0) }.map { Scheme(name: $0, isShared: false) }
        return ProjectSnapshot(
            container: container,
            schemes: quick.schemes + extra,
            targets: quick.targets,
            // The project file is the source for a project; a workspace's own listing has none.
            configurations: quick.configurations.isEmpty ? listing.configurations : quick.configurations,
            defaultConfiguration: quick.defaultConfiguration,
            config: quick.config,
            configProblem: quick.configProblem
        )
    }

    // MARK: - Files

    private func projectURLs(of container: ProjectContainer) throws -> [URL] {
        switch container.kind {
        case .project:
            return [container.url]
        case .workspace:
            let dataURL = container.url.appendingPathComponent(Layout.workspaceFile)
            // A workspace inside a project bundle (project.xcworkspace) has no projects of its own.
            guard let data = try? Data(contentsOf: dataURL) else { return [] }
            return try reading(dataURL) { try WorkspaceFileParser.projectURLs(in: data, workspaceURL: container.url) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    private func projectFile(at projectURL: URL) throws -> ProjectFile {
        let url = projectURL.appendingPathComponent(Layout.projectFile)
        return try reading(url) { try ProjectFileParser.parse(Data(contentsOf: url)) }
    }

    /// Shared schemes first, then each user's own; a shared scheme wins over a user scheme of the same name.
    private func schemes(in containerURL: URL) throws -> [Scheme] {
        var schemes: [Scheme] = []
        let shared = containerURL.appendingPathComponent(Layout.sharedSchemesPath)
        let userFolders = contents(of: containerURL.appendingPathComponent(Layout.userDataFolder))
            .map { $0.appendingPathComponent(Layout.userSchemesFolder) }

        for (folder, isShared) in [(shared, true)] + userFolders.map({ ($0, false) }) {
            for url in contents(of: folder) where url.pathExtension == Layout.schemeExtension {
                let name = url.deletingPathExtension().lastPathComponent
                guard !schemes.contains(where: { $0.name == name }) else { continue }
                schemes.append(try reading(url) {
                    try SchemeFileParser.parse(Data(contentsOf: url), name: name, isShared: isShared)
                })
            }
        }
        return schemes
    }

    private func contents(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }

    /// Turns any read or parse failure into one error that names the file.
    private func reading<T>(_ url: URL, _ work: () throws -> T) throws -> T {
        do {
            return try work()
        } catch let error as BuildDeskError {
            throw error
        } catch {
            throw BuildDeskError.unreadableProject(path: url.path, reason: error.localizedDescription)
        }
    }
}

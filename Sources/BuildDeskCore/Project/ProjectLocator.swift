import Foundation

/// Finds the Xcode project to open when the user picks a folder (a repository checkout) instead of
/// the project itself.
public enum ProjectLocator {
    /// How many folder levels below the chosen folder are searched. Projects usually sit at the
    /// top or one folder down; searching deeper would walk dependencies and build output.
    public static let searchDepth = 2

    /// Resolves what the user chose: a project or workspace is used as it is; a folder is searched.
    public static func container(at url: URL) throws -> ProjectContainer {
        if let container = try? ProjectContainer(url: url) { return container }
        guard let found = containers(in: url).first else {
            throw BuildDeskError.unsupportedContainer(path: url.path)
        }
        return found
    }

    /// Projects and workspaces in a folder, nearest first; at the same level a workspace comes
    /// before a project, because a workspace is what a project with one is meant to be opened with.
    public static func containers(in folder: URL, depth: Int = searchDepth) -> [ProjectContainer] {
        guard depth > 0 else { return [] }
        let children = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        let here = children.compactMap { try? ProjectContainer(url: $0) }
            .sorted { $0.kind == .workspace && $1.kind == .project }
        let below = children
            .filter { (try? ProjectContainer(url: $0)) == nil && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .flatMap { containers(in: $0, depth: depth - 1) }
        return here + below
    }
}

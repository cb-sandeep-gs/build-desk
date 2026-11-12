import Foundation

/// Builds the argument list of every Apple tool call Build Desk makes. Kept together so the exact
/// commands can be read, and tested, in one place.
public enum AppleTools {
    private typealias Path = BuildDeskConstants.ToolPath

    // MARK: - xcodebuild

    public static func listProject(_ container: ProjectContainer) -> ToolCommand {
        ToolCommand(executable: Path.xcodebuild, arguments: ["-list", "-json"] + containerArguments(container))
    }

    public static func build(_ request: BuildRequest) -> ToolCommand {
        ToolCommand(executable: Path.xcodebuild, arguments: buildArguments(request) + ["build"])
    }

    /// Asks where the build put its products. Uses the same arguments as `build`, so the app that
    /// gets installed is the one that build produced.
    public static func buildSettings(_ request: BuildRequest) -> ToolCommand {
        ToolCommand(executable: Path.xcodebuild, arguments: buildArguments(request) + ["-showBuildSettings", "-json"])
    }

    // MARK: - devicectl (real devices)

    public static func listDevices(jsonOutput: URL) -> ToolCommand {
        xcrun(["devicectl", "list", "devices", "--json-output", jsonOutput.path])
    }

    public static func installOnDevice(udid: String, app: URL) -> ToolCommand {
        xcrun(["devicectl", "device", "install", "app", "--device", udid, app.path])
    }

    /// `--terminate-existing` replaces a running copy, so the new build is what opens.
    public static func launchOnDevice(udid: String, bundleIdentifier: String) -> ToolCommand {
        xcrun(["devicectl", "device", "process", "launch", "--device", udid, "--terminate-existing", bundleIdentifier])
    }

    // MARK: - simctl (simulators)

    public static func listSimulators() -> ToolCommand {
        xcrun(["simctl", "list", "devices", "--json"])
    }

    /// `bootstatus -b` boots the simulator if needed and returns once it has finished booting.
    public static func bootSimulator(udid: String) -> ToolCommand {
        xcrun(["simctl", "bootstatus", udid, "-b"])
    }

    public static func installOnSimulator(udid: String, app: URL) -> ToolCommand {
        xcrun(["simctl", "install", udid, app.path])
    }

    public static func launchOnSimulator(udid: String, bundleIdentifier: String) -> ToolCommand {
        xcrun(["simctl", "launch", "--terminate-running-process", udid, bundleIdentifier])
    }

    // MARK: - Shared

    private static func xcrun(_ arguments: [String]) -> ToolCommand {
        ToolCommand(executable: Path.xcrun, arguments: arguments)
    }

    private static func containerArguments(_ container: ProjectContainer) -> [String] {
        [container.kind == .workspace ? "-workspace" : "-project", container.url.path]
    }

    /// No `-derivedDataPath`, on purpose: the build goes to Xcode's own DerivedData and stays
    /// incremental with builds made from Xcode.
    private static func buildArguments(_ request: BuildRequest) -> [String] {
        var arguments = containerArguments(request.container) + [
            "-scheme", request.scheme,
            "-configuration", request.configuration,
            "-destination", "id=\(request.device.id)",
        ]
        // Lets xcodebuild create or refresh provisioning profiles with the account saved in Xcode.
        // Simulator builds are not provisioned.
        if request.device.kind == .physical { arguments.append("-allowProvisioningUpdates") }
        return arguments
    }
}

import Foundation

// The three services the app is built on, as protocols, so view models are tested with fakes.

/// Reads a project's schemes, targets and configurations.
public protocol ProjectReading: Sendable {
    /// From the project's own files; returns at once.
    func quickSnapshot(of container: ProjectContainer) throws -> ProjectSnapshot
    /// Adds schemes only `xcodebuild` knows; can take tens of seconds.
    func fullSnapshot(of container: ProjectContainer) async throws -> ProjectSnapshot
}

/// Finds devices and simulators.
public protocol DeviceDiscovering: Sendable {
    func devices() async throws -> [Device]
    /// Whether a real device is waiting for its passcode; nil when it cannot be told.
    func isLocked(_ device: Device) async -> Bool?
}

extension DeviceDiscovering {
    public func isLocked(_ device: Device) async -> Bool? { nil }
}

/// Runs a build, install and launch, reporting progress as events.
public protocol BuildRunning: Sendable {
    func run(_ request: BuildRequest) -> AsyncThrowingStream<PipelineEvent, Error>
    /// Installs an app file without building.
    func install(_ request: InstallRequest) -> AsyncThrowingStream<PipelineEvent, Error>
}

/// Reads a `.app` or `.ipa` the user chose.
public protocol ArtifactReading: Sendable {
    func read(_ url: URL) async throws -> AppArtifact
}

/// Works with an app that is already on a device.
public protocol DeviceAppManaging: Sendable {
    /// Launches the app and delivers what it prints, line by line, until it exits or the
    /// consumer stops.
    func console(bundleIdentifier: String, on device: Device, options: LaunchOptions) -> AsyncThrowingStream<String, Error>
    func uninstall(bundleIdentifier: String, from device: Device) async throws
}

/// Says which branch and commit a project's checkout is on.
public protocol SourceStateReading: Sendable {
    /// Nil when the folder is not in a git checkout.
    func state(of folder: URL) async -> SourceState?
}

extension ProjectReader: ProjectReading {}
extension DeviceDiscovery: DeviceDiscovering {}
extension BuildPipeline: BuildRunning {}
extension ArtifactReader: ArtifactReading {}
extension DeviceAppService: DeviceAppManaging {}
extension SourceStateReader: SourceStateReading {}

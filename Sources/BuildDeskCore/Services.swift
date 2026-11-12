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
}

/// Runs a build, install and launch, reporting progress as events.
public protocol BuildRunning: Sendable {
    func run(_ request: BuildRequest) -> AsyncThrowingStream<PipelineEvent, Error>
}

extension ProjectReader: ProjectReading {}
extension DeviceDiscovery: DeviceDiscovering {}
extension BuildPipeline: BuildRunning {}

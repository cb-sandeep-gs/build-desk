import BuildDeskCore
import Foundation

/// The state of something loaded in the background, so every view can show loading, content or a
/// failure the same way.
public enum LoadState<Value: Sendable & Equatable>: Sendable, Equatable {
    case idle
    case loading
    case loaded(Value)
    case failed(String)

    public var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }
}

/// The services the app runs on. The live set drives the real tools; tests and the demo mode pass
/// their own.
public struct AppEnvironment: Sendable {
    public let reader: any ProjectReading
    public let discovery: any DeviceDiscovering
    public let builder: any BuildRunning
    /// True while Xcode is open; an open Xcode can make command-line builds fail.
    public let isXcodeOpen: @MainActor @Sendable () -> Bool

    public init(
        reader: any ProjectReading,
        discovery: any DeviceDiscovering,
        builder: any BuildRunning,
        isXcodeOpen: @escaping @MainActor @Sendable () -> Bool
    ) {
        self.reader = reader
        self.discovery = discovery
        self.builder = builder
        self.isXcodeOpen = isXcodeOpen
    }
}

/// The text of an error as the user should read it.
func userMessage(for error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}

/// What the app remembers between launches. Small values only, in UserDefaults.
@MainActor
public final class PreferenceStore {
    private enum Key {
        static let recentProjects = "recentProjects"
        static let lastScheme = "lastScheme"
        static let lastConfiguration = "lastConfiguration"
        static let lastDevice = "lastDevice"
        static let launchesAfterInstall = "launchesAfterInstall"
        static let taskCounts = "taskCounts"
    }

    /// How many recently opened projects are remembered.
    public static let recentProjectLimit = 8

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Most recently opened first.
    public var recentProjects: [URL] {
        get { (defaults.stringArray(forKey: Key.recentProjects) ?? []).map { URL(fileURLWithPath: $0) } }
        set { defaults.set(newValue.prefix(Self.recentProjectLimit).map(\.path), forKey: Key.recentProjects) }
    }

    public func noteOpened(_ url: URL) {
        recentProjects = [url] + recentProjects.filter { $0.path != url.path }
    }

    public func forget(_ url: URL) {
        recentProjects = recentProjects.filter { $0.path != url.path }
    }

    public var lastDeviceID: String? {
        get { defaults.string(forKey: Key.lastDevice) }
        set { defaults.set(newValue, forKey: Key.lastDevice) }
    }

    /// Defaults to true: opening the app after installing it is what "run" means.
    public var launchesAfterInstall: Bool {
        get { defaults.object(forKey: Key.launchesAfterInstall) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.launchesAfterInstall) }
    }

    public func lastScheme(for project: URL) -> String? { dictionary(Key.lastScheme)[project.path] }
    public func setLastScheme(_ scheme: String?, for project: URL) { update(Key.lastScheme, project.path, scheme) }

    public func lastConfiguration(for project: URL) -> String? { dictionary(Key.lastConfiguration)[project.path] }
    public func setLastConfiguration(_ name: String?, for project: URL) { update(Key.lastConfiguration, project.path, name) }

    /// How many build tasks the last successful build of this scheme ran. `xcodebuild` never says
    /// how many tasks a build will have, so the last count is what progress is estimated against.
    public func taskCount(for key: String) -> Int? { dictionary(Key.taskCounts)[key].flatMap(Int.init) }
    public func setTaskCount(_ count: Int, for key: String) { update(Key.taskCounts, key, String(count)) }

    private func dictionary(_ key: String) -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    private func update(_ key: String, _ entry: String, _ value: String?) {
        var values = dictionary(key)
        values[entry] = value
        defaults.set(values, forKey: key)
    }
}

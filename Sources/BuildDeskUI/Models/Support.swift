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
    /// Tells the user a run ended when they are not looking at Build Desk.
    public let notifier: any RunNotifying
    /// True while Build Desk is the frontmost app; a notification would only repeat what is on screen.
    public let isAppActive: @MainActor @Sendable () -> Bool
    /// Reads a dropped `.app` or `.ipa`.
    public let artifacts: any ArtifactReading
    /// Console and uninstall for installed apps.
    public let deviceApps: any DeviceAppManaging
    /// Branch and commit of a project's checkout.
    public let source: any SourceStateReading
    /// Past runs and the warnings already seen.
    public let history: any RunHistoryStoring
    /// The project's build output on disk.
    public let buildFolders: any BuildFolderManaging
    /// Runs a scheme's tests.
    public let tester: any TestRunning
    /// Screenshots, app data and crash logs from a device.
    public let deviceTools: any DeviceToolsProviding
    /// The project's own release commands.
    public let releases: any ReleaseProviding
    /// The project's code at a tagged commit, to build a release build from.
    public let taggedSources: any TaggedSourcePreparing

    public init(
        reader: any ProjectReading,
        discovery: any DeviceDiscovering,
        builder: any BuildRunning,
        isXcodeOpen: @escaping @MainActor @Sendable () -> Bool,
        notifier: any RunNotifying = SilentNotifier(),
        isAppActive: @escaping @MainActor @Sendable () -> Bool = { true },
        artifacts: any ArtifactReading = InertServices(),
        deviceApps: any DeviceAppManaging = InertServices(),
        source: any SourceStateReading = InertServices(),
        history: any RunHistoryStoring = MemoryRunHistoryStore(),
        buildFolders: any BuildFolderManaging = InertServices(),
        tester: any TestRunning = InertServices(),
        deviceTools: any DeviceToolsProviding = InertServices(),
        releases: any ReleaseProviding = InertServices(),
        taggedSources: any TaggedSourcePreparing = InertServices()
    ) {
        self.reader = reader
        self.discovery = discovery
        self.builder = builder
        self.isXcodeOpen = isXcodeOpen
        self.notifier = notifier
        self.isAppActive = isAppActive
        self.artifacts = artifacts
        self.deviceApps = deviceApps
        self.source = source
        self.history = history
        self.buildFolders = buildFolders
        self.tester = tester
        self.deviceTools = deviceTools
        self.releases = releases
        self.taggedSources = taggedSources
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
        static let pins = "pins"
        static let installRecords = "installRecords"
        static let launchTexts = "launchTexts"
        static let scheduleIsEnabled = "scheduleIsEnabled"
        static let scheduleMinuteOfDay = "scheduleMinuteOfDay"
        static let watchesReleases = "watchesReleases"
    }

    /// 09:00, a little before most working days start.
    public static let defaultScheduleMinuteOfDay = 9 * 60

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

    /// Scheme and device pairs shown in the menu bar, in the order they were pinned.
    public var pins: [PinnedRun] {
        get { defaults.data(forKey: Key.pins).flatMap { try? JSONDecoder().decode([PinnedRun].self, from: $0) } ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.pins) }
    }

    /// The last install of each scheme on each device, by `InstallRecord.key`.
    public var installRecords: [String: InstallRecord] {
        get {
            defaults.data(forKey: Key.installRecords).flatMap { try? JSONDecoder().decode([String: InstallRecord].self, from: $0) } ?? [:]
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.installRecords) }
    }

    /// Launch options per project and scheme, as typed.
    public var launchTexts: [String: LaunchTexts] {
        get { defaults.data(forKey: Key.launchTexts).flatMap { try? JSONDecoder().decode([String: LaunchTexts].self, from: $0) } ?? [:] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.launchTexts) }
    }

    /// Whether the pins are built once a day.
    public var scheduleIsEnabled: Bool {
        get { defaults.bool(forKey: Key.scheduleIsEnabled) }
        set { defaults.set(newValue, forKey: Key.scheduleIsEnabled) }
    }

    /// The time of that daily build, in minutes after midnight.
    /// Defaults to true: a project that can tell its store state is watched unless the person says no.
    public var watchesReleases: Bool {
        get { defaults.object(forKey: Key.watchesReleases) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.watchesReleases) }
    }

    public var scheduleMinuteOfDay: Int {
        get { defaults.object(forKey: Key.scheduleMinuteOfDay) as? Int ?? Self.defaultScheduleMinuteOfDay }
        set { defaults.set(newValue, forKey: Key.scheduleMinuteOfDay) }
    }

    private func dictionary(_ key: String) -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    private func update(_ key: String, _ entry: String, _ value: String?) {
        var values = dictionary(key)
        values[entry] = value
        defaults.set(values, forKey: key)
    }
}

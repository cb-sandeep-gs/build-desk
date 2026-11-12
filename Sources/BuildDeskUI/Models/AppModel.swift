import BuildDeskCore
import Foundation
import Observation

/// The whole app's state: the open project, the device list and the current run.
@MainActor
@Observable
public final class AppModel {
    public private(set) var project: ProjectModel?
    public let devices: DeviceListModel
    public let run: RunModel
    public private(set) var recentProjects: [URL]
    /// Why the last attempt to open a project failed, until the next attempt.
    public private(set) var openError: String?
    public private(set) var isXcodeOpen = false
    public var launchesAfterInstall: Bool {
        didSet { store.launchesAfterInstall = launchesAfterInstall }
    }
    /// Scheme and device pairs shown in the menu bar.
    public private(set) var pins: [PinnedRun] {
        didSet { store.pins = pins }
    }
    /// Why the last pin could not be run, until the next attempt.
    public private(set) var pinError: String?

    private let environment: AppEnvironment
    private let store: PreferenceStore

    public init(environment: AppEnvironment, store: PreferenceStore = PreferenceStore()) {
        self.environment = environment
        self.store = store
        devices = DeviceListModel(discovery: environment.discovery, store: store)
        run = RunModel(builder: environment.builder)
        recentProjects = store.recentProjects
        launchesAfterInstall = store.launchesAfterInstall
        pins = store.pins
    }

    // MARK: - Projects

    /// Opens a project, a workspace, or a folder that contains one.
    public func open(_ url: URL) async {
        do {
            let container = try ProjectLocator.container(at: url)
            openError = nil
            let model = ProjectModel(container: container, reader: environment.reader, store: store)
            project = model
            store.noteOpened(container.url)
            recentProjects = store.recentProjects
            await model.load()
        } catch {
            openError = userMessage(for: error)
        }
    }

    /// Reopens the project that was open last time, if it still exists.
    public func restoreLastProject() async {
        guard project == nil, let last = recentProjects.first else { return }
        guard FileManager.default.fileExists(atPath: last.path) else {
            store.forget(last)
            recentProjects = store.recentProjects
            return
        }
        await open(last)
    }

    public func closeProject() {
        project = nil
    }

    // MARK: - Devices

    /// Devices the selected scheme can go on: a watch app is not offered an iPhone.
    public var devicesForSelectedScheme: [Device] {
        guard let snapshot = project?.snapshot, let scheme = project?.selectedScheme else { return devices.devices }
        return devices.devices.filter { snapshot.canInstall(scheme, on: $0) }
    }

    /// The chosen device, if it fits the selected scheme; else the first one that is ready.
    public var selectedDevice: Device? {
        let fitting = devicesForSelectedScheme
        return fitting.first { $0.id == devices.selectedDeviceID } ?? fitting.first { $0.isReady }
    }

    /// Called while the window is on screen.
    public func refreshEnvironment() async {
        isXcodeOpen = environment.isXcodeOpen()
        await devices.refresh()
    }

    // MARK: - Running

    /// Why a run cannot start now, in words for the user; nil when it can.
    public var runBlocker: String? {
        if run.isRunning { return "A build is running." }
        guard project?.selectedScheme != nil else { return "Choose a scheme." }
        guard let device = selectedDevice else { return "Connect a device or choose a simulator." }
        guard device.isReady else { return "\(device.name) is not connected. Connect and unlock it." }
        return nil
    }

    /// Starts a run of the selected scheme on the selected device.
    public func runSelected(_ mode: RunMode) {
        guard runBlocker == nil, let project, let scheme = project.selectedScheme, let device = selectedDevice else { return }
        // Installing without building only makes sense for a scheme that has an app.
        guard mode != .installOnly || scheme.isInstallable else { return }
        let request = BuildRequest(
            container: project.container,
            scheme: scheme.name,
            configuration: project.selectedConfiguration,
            device: device,
            builds: mode != .installOnly,
            // A scheme with no app is built, whatever was asked for.
            installs: mode != .buildOnly && scheme.isInstallable,
            launches: launchesAfterInstall
        )
        let key = Self.taskCountKey(
            project: request.container.url, scheme: request.scheme, configuration: request.configuration, deviceKind: device.kind
        )
        run.start(request, expectedTaskCount: store.taskCount(for: key))
        Task { [weak self] in
            guard let self else { return }
            await run.waitUntilFinished()
            guard run.request == request else { return }
            // Remember how big this build was, to estimate the next one's progress.
            if run.phase == .succeeded, run.taskCount > 0 { store.setTaskCount(run.taskCount, for: key) }
            // Someone looking at the window has already seen the result.
            if !environment.isAppActive(), let notice = RunNotice.make(for: run) { await environment.notifier.post(notice) }
        }
    }

    /// The key a build's task count is remembered under. Simulator and device builds of one
    /// scheme are different builds with different task counts.
    static func taskCountKey(project: URL, scheme: String, configuration: String, deviceKind: Device.Kind) -> String {
        [project.path, scheme, configuration, deviceKind.rawValue].joined(separator: "|")
    }

    // MARK: - Pins

    /// The current scheme, configuration and device as a pin; nil until all three are chosen.
    public var pinForSelection: PinnedRun? {
        guard let project, let scheme = project.selectedScheme, let device = selectedDevice else { return nil }
        return PinnedRun(
            project: project.container.url, scheme: scheme.name, configuration: project.selectedConfiguration,
            deviceID: device.id, deviceName: device.name
        )
    }

    public var isSelectionPinned: Bool {
        pinForSelection.map { pin in pins.contains { $0.id == pin.id } } ?? false
    }

    /// Adds the current selection to the menu bar, or takes it out if it is there.
    public func togglePinForSelection() {
        guard let pin = pinForSelection else { return }
        if isSelectionPinned { remove(pin) } else { pins.append(pin) }
    }

    public func remove(_ pin: PinnedRun) {
        pins.removeAll { $0.id == pin.id }
    }

    /// The device a pin points at, if this Mac can see it now.
    public func device(for pin: PinnedRun) -> Device? {
        devices.devices.first { $0.id == pin.deviceID }
    }

    /// Runs a pin: opens its project if another is open, selects its scheme, configuration and
    /// device, then builds and installs.
    public func run(_ pin: PinnedRun) async {
        guard !run.isRunning else { return }
        pinError = nil
        if project?.container.url != pin.project { await open(pin.project) }
        guard let project, project.container.url == pin.project, project.snapshot?.scheme(named: pin.scheme) != nil else {
            pinError = openError ?? "The scheme \(pin.scheme) is no longer in \(pin.project.deletingPathExtension().lastPathComponent)."
            return
        }
        project.selectedSchemeName = pin.scheme
        if project.snapshot?.configurations.contains(pin.configuration) == true { project.selectedConfiguration = pin.configuration }
        // The device may have been plugged in since the last refresh.
        await devices.refresh()
        devices.selectedDeviceID = pin.deviceID
        guard let device = selectedDevice, device.id == pin.deviceID, device.isReady else {
            pinError = "\(pin.deviceName) is not connected. Connect and unlock it."
            return
        }
        runSelected(.buildAndInstall)
    }
}

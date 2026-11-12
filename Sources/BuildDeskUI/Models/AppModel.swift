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

    private let environment: AppEnvironment
    private let store: PreferenceStore

    public init(environment: AppEnvironment, store: PreferenceStore = PreferenceStore()) {
        self.environment = environment
        self.store = store
        devices = DeviceListModel(discovery: environment.discovery, store: store)
        run = RunModel(builder: environment.builder)
        recentProjects = store.recentProjects
        launchesAfterInstall = store.launchesAfterInstall
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
    /// - Parameter installs: false builds only.
    public func runSelected(installs: Bool) {
        guard runBlocker == nil, let project, let scheme = project.selectedScheme, let device = selectedDevice else { return }
        let request = BuildRequest(
            container: project.container,
            scheme: scheme.name,
            configuration: project.selectedConfiguration,
            device: device,
            installs: installs && scheme.isInstallable,
            launches: launchesAfterInstall
        )
        let key = Self.taskCountKey(
            project: request.container.url, scheme: request.scheme, configuration: request.configuration, deviceKind: device.kind
        )
        run.start(request, expectedTaskCount: store.taskCount(for: key))
        Task { [weak self] in
            guard let self else { return }
            await run.waitUntilFinished()
            // Remember how big this build was, to estimate the next one's progress.
            if run.phase == .succeeded, run.request == request, run.taskCount > 0 {
                store.setTaskCount(run.taskCount, for: key)
            }
        }
    }

    /// The key a build's task count is remembered under. Simulator and device builds of one
    /// scheme are different builds with different task counts.
    static func taskCountKey(project: URL, scheme: String, configuration: String, deviceKind: Device.Kind) -> String {
        [project.path, scheme, configuration, deviceKind.rawValue].joined(separator: "|")
    }
}

import BuildDeskCore
import Foundation

// What the app model does beyond opening a project and running a build: installed apps, app
// files and build insight.

// MARK: - Installed apps

extension AppModel {
    /// What Build Desk last installed for the selected scheme on the selected device.
    public var lastInstall: InstallRecord? {
        guard let project, let scheme = project.selectedSchemeName, let device = selectedDevice else { return nil }
        return installRecords[InstallRecord.key(project: project.container.url, scheme: scheme, deviceID: device.id)]
    }

    /// Opens the console of the app last installed for the selection, started the same way a
    /// run starts it.
    public func openConsoleForSelection() {
        guard let record = lastInstall, let device = selectedDevice else { return }
        let options = (try? launchTextsForSelection.options().get()) ?? LaunchOptions()
        console.start(bundleIdentifier: record.bundleIdentifier, on: device, options: options)
    }

    // MARK: Launch options

    static func launchTextsKey(project: URL, scheme: String) -> String {
        [project.path, scheme].joined(separator: "|")
    }

    /// The launch options of the selected scheme, as typed. Each scheme keeps its own.
    public var launchTextsForSelection: LaunchTexts {
        get {
            guard let project, let scheme = project.selectedSchemeName else { return LaunchTexts() }
            return launchTexts[Self.launchTextsKey(project: project.container.url, scheme: scheme)] ?? LaunchTexts()
        }
        set {
            guard let project, let scheme = project.selectedSchemeName else { return }
            // Nothing typed is no entry, so the stored dictionary does not fill with blanks.
            launchTexts[Self.launchTextsKey(project: project.container.url, scheme: scheme)] = newValue.isEmpty ? nil : newValue
        }
    }

    /// Removes the app last installed for the selection from the selected device. The caller asks
    /// the user to confirm first.
    public func uninstallSelection() async {
        guard let project, let scheme = project.selectedSchemeName, let record = lastInstall, let device = selectedDevice else { return }
        do {
            try await environment.deviceApps.uninstall(bundleIdentifier: record.bundleIdentifier, from: device)
            installRecords[InstallRecord.key(project: project.container.url, scheme: scheme, deviceID: device.id)] = nil
            uninstallMessage = "Removed \(scheme) from \(device.name)."
        } catch {
            uninstallMessage = userMessage(for: error)
        }
    }

    // MARK: App files

    /// Ready devices the waiting app file can go on.
    public var devicesForPendingArtifact: [Device] {
        guard let artifact = pendingArtifact else { return [] }
        return devices.devices.filter { $0.isReady && artifact.fits($0) }
    }

    /// Installs the waiting app file on the chosen devices.
    public func installPendingArtifact(on deviceIDs: Set<String>) {
        guard let artifact = pendingArtifact, !run.isRunning else { return }
        let targets = devicesForPendingArtifact.filter { deviceIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        run.start(InstallRequest(artifact: artifact, devices: targets, launches: launchesAfterInstall))
        Task { [weak self] in
            await self?.run.waitUntilFinished()
            await self?.announceIfInBackground()
        }
    }

    public func dismissPendingArtifact() {
        pendingArtifact = nil
    }
}

// MARK: - Device tools

extension AppModel {
    /// Crash reports copied at once: the newest ones are what a person is looking for.
    public static let crashLogLimit = 20

    /// True when a device tool can be used: a ready device, and nothing else going on.
    public var canUseDeviceTools: Bool {
        selectedDevice?.isReady == true && !isUsingDeviceTool && !run.isRunning && !tests.isRunning
    }

    /// The name the app runs under on the device, which crash reports are named after.
    var processNameForSelection: String? {
        guard let scheme = project?.selectedScheme, let product = (scheme.runnable ?? scheme.buildTargets.first)?.productName else {
            return nil
        }
        return URL(fileURLWithPath: product).deletingPathExtension().lastPathComponent
    }

    /// Saves a picture of the selected device's screen in `folder`.
    public func takeScreenshot(in folder: URL) async {
        guard canUseDeviceTools, let device = selectedDevice else { return }
        let file = folder.appendingPathComponent("\(device.name) \(Self.fileStamp()).png")
        await useDeviceTool(saving: file, success: "Screenshot of \(device.name) saved.") {
            try await self.environment.deviceTools.screenshot(of: device, to: file)
        }
    }

    /// Copies the data of the app last installed for the selection into a new folder in `folder`.
    public func downloadAppData(to folder: URL) async {
        guard canUseDeviceTools, let device = selectedDevice, let record = lastInstall, let scheme = project?.selectedSchemeName
        else { return }
        let destination = folder.appendingPathComponent("\(scheme) data \(Self.fileStamp())")
        await useDeviceTool(saving: destination, success: "App data of \(scheme) copied from \(device.name).") {
            try await self.environment.deviceTools.copyAppData(bundleIdentifier: record.bundleIdentifier, from: device, to: destination)
        }
    }

    /// Copies the newest crash reports of the selected scheme's app into a new folder in `folder`.
    public func saveCrashLogs(to folder: URL) async {
        guard canUseDeviceTools, let device = selectedDevice, let process = processNameForSelection else { return }
        let destination = folder.appendingPathComponent("\(process) crash logs \(Self.fileStamp())")
        isUsingDeviceTool = true
        defer { isUsingDeviceTool = false }
        do {
            let logs = Array(try await environment.deviceTools.crashLogs(forProcess: process, on: device).prefix(Self.crashLogLimit))
            guard !logs.isEmpty else {
                deviceToolResult = nil
                return deviceToolMessage = "No crash logs for \(process) on \(device.name)."
            }
            try await environment.deviceTools.copy(logs, from: device, to: destination)
            deviceToolResult = destination
            deviceToolMessage = "\(logs.count) crash log\(logs.count == 1 ? "" : "s") of \(process) saved."
        } catch {
            deviceToolResult = nil
            deviceToolMessage = userMessage(for: error)
        }
    }

    private func useDeviceTool(saving url: URL, success: String, _ work: () async throws -> Void) async {
        isUsingDeviceTool = true
        defer { isUsingDeviceTool = false }
        do {
            try await work()
            deviceToolResult = url
            deviceToolMessage = success
        } catch {
            deviceToolResult = nil
            deviceToolMessage = userMessage(for: error)
        }
    }

    /// "2026-01-01 at 10.15.00": sorts by name in time order and is valid in a file name.
    static func fileStamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }
}

// MARK: - Tests

extension AppModel {
    /// True when the selected scheme has tests to run.
    public var canTestSelection: Bool {
        !(project?.selectedScheme?.testTargets.isEmpty ?? true)
    }

    /// Runs the selected scheme's tests on the selected device.
    /// - Parameter only: limits the run, each entry as "Bundle", "Bundle/Class" or "Bundle/Class/test".
    public func runTests(only: [String] = []) {
        guard runBlocker == nil, canTestSelection, let project, let scheme = project.selectedScheme, let device = selectedDevice
        else { return }
        tests.start(TestRequest(
            container: project.container, scheme: scheme.name, configuration: project.selectedConfiguration,
            device: device, onlyTesting: only
        ))
        Task { [weak self] in
            guard let self else { return }
            await tests.waitUntilFinished()
            if !environment.isAppActive(), let notice = RunNotice.make(for: tests) { await environment.notifier.post(notice) }
        }
    }

    /// Runs again only the tests that failed in the last run.
    public func rerunFailedTests() {
        guard let failed = tests.summary?.failed, !failed.isEmpty else { return }
        runTests(only: failed.map(\.id))
    }
}

// MARK: - Build insight

extension AppModel {
    /// Past runs of the selected scheme, newest first.
    public var historyForSelectedScheme: [RunRecord] {
        guard let scheme = project?.selectedSchemeName else { return [] }
        return history.filter { $0.scheme == scheme }
    }

    /// Deletes the open project's build output. The caller asks the user to confirm first.
    public func cleanBuildFolder() async {
        guard let project, let folder = buildFolder, !isCleaningBuildFolder else { return }
        guard !run.isRunning else { return buildFolderMessage = "Wait for the running build to finish." }
        // Xcode keeps files in the build folder open while a project is open in it.
        guard !environment.isXcodeOpen() else {
            return buildFolderMessage = "Xcode is open. Quit it first, or use Product ▸ Clean Build Folder in Xcode."
        }
        isCleaningBuildFolder = true
        defer { isCleaningBuildFolder = false }
        do {
            try await environment.buildFolders.clean(folder)
            let freed = folder.buildBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "The space"
            buildFolderMessage = "\(freed) freed. The next build will be a full one."
        } catch {
            buildFolderMessage = "Couldn't clean the build folder: \(userMessage(for: error))"
        }
        buildFolder = await environment.buildFolders.buildFolder(for: project.container)
    }

    func reloadInsight(for container: ProjectContainer) async {
        history = await environment.history.records(forProject: container.url.path)
        buildFolder = await environment.buildFolders.buildFolder(for: container)
    }

    /// Adds the finished run to the history and works out which of its warnings are new.
    func recordRun(of request: BuildRequest, source: SourceState?) async {
        let projectPath = request.container.url.path
        var newCount: Int?
        if run.phase == .succeeded, request.builds, let summary = run.summary {
            let key = WarningDiff.key(projectPath: projectPath, scheme: request.scheme, configuration: request.configuration)
            // Before the first build there is nothing to call "new" against.
            if let known = await environment.history.knownWarnings(for: key) {
                let fresh = WarningDiff.newWarnings(in: summary.warnings, known: known)
                newWarnings = fresh
                newCount = fresh.count
            }
            await environment.history.addKnownWarnings(Set(summary.warnings.map(\.fingerprint)), for: key)
        }
        let buildSeconds: Double? = if case .done(let seconds) = run.statuses[.build] { seconds } else { nil }
        let result: RunRecord.Result = switch run.phase {
        case .succeeded: .succeeded
        case .stopped: .stopped
        case .idle, .running, .failed: .failed
        }
        await environment.history.append(RunRecord(
            date: run.finishedAt ?? Date(),
            projectPath: projectPath,
            scheme: request.scheme,
            configuration: request.configuration,
            deviceName: request.device.name,
            deviceKind: request.device.kind,
            action: !request.builds ? .installOnly : request.installs ? .buildAndInstall : .buildOnly,
            result: result,
            totalSeconds: (run.finishedAt ?? Date()).timeIntervalSince(run.startedAt ?? Date()),
            buildSeconds: buildSeconds,
            taskCount: run.taskCount,
            warningCount: run.summary?.warnings.count ?? run.warnings.count,
            newWarningCount: newCount,
            errorCount: run.errors.count,
            source: source
        ))
        // The build changed what is on disk, so measure again along with reloading the list.
        await reloadInsight(for: request.container)
    }
}

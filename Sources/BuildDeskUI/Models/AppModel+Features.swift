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

import BuildDeskCore
import Foundation

/// A release build being built from its tagged code on this Mac and installed on a device.
public struct TaggedInstall: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// The code at the build's commit is being made ready.
        case preparing
        /// Handed to the run; `RunModel` has the progress and the result.
        case running
        case failed(String)
    }

    public let build: ReleaseBuild
    public let scheme: String
    public let configuration: String
    public let deviceName: String
    public internal(set) var phase: Phase
    /// The run's request, once the code is ready.
    var request: BuildRequest?
}

extension AppModel {
    /// The scheme that builds a release build's app: the one the project's release commands name
    /// for the app, else the scheme selected in Build mode.
    public func taggedScheme(for build: ReleaseBuild) -> Scheme? {
        let named = release?.status?.apps.first { $0.id == build.app }?.scheme
        let scheme = named.flatMap { project?.snapshot?.scheme(named: $0) } ?? project?.selectedScheme
        return scheme?.isInstallable == true ? scheme : nil
    }

    /// Why a release build can't be built and installed right now; nil when it can.
    public func taggedInstallBlocker(for build: ReleaseBuild) -> String? {
        if taggedInstall?.phase == .preparing { return "Another build's code is being made ready." }
        if run.isRunning { return "A build is running." }
        if tests.isRunning { return "Tests are running." }
        guard build.commit != nil else { return "The project does not say which commit this build was made from." }
        guard taggedScheme(for: build) != nil else { return "Choose the app's scheme in Build mode first." }
        guard let device = selectedDevice else { return "Connect a device or choose a simulator in Build mode." }
        guard device.isReady else { return (device.issue ?? .notConnected).fix(for: device.name) }
        return nil
    }

    /// What pressing the button will do, for the confirmation.
    public func taggedInstallSummary(for build: ReleaseBuild) -> String? {
        guard let project, let scheme = taggedScheme(for: build), let device = selectedDevice else { return nil }
        return "Build Desk builds \(scheme.name) (\(project.selectedConfiguration)) from the code of \(build.id) on this Mac "
            + "and installs it on \(device.name). This is the tagged code built here, not the file testers have, and it "
            + "replaces the app on the device. Your checkout is not touched; the first build from a tag is a full one."
    }

    /// True while the last tagged install is what the run shows.
    public var showsTaggedInstall: Bool {
        guard let install = taggedInstall else { return false }
        return install.phase != .running || run.request == install.request
    }

    /// Builds a release build from its tagged code and installs it on the selected device.
    /// The caller asks the person to confirm first.
    public func installTagged(_ build: ReleaseBuild) async {
        guard taggedInstallBlocker(for: build) == nil, let project, let scheme = taggedScheme(for: build),
              let device = selectedDevice, let commit = build.commit else { return }
        taggedInstall = TaggedInstall(
            build: build, scheme: scheme.name, configuration: project.selectedConfiguration, deviceName: device.name, phase: .preparing
        )
        let source: TaggedSource
        do {
            source = try await environment.taggedSources.prepare(commit: commit, of: project.container)
        } catch {
            taggedInstall?.phase = .failed(userMessage(for: error))
            return
        }
        // Something else may have been started while the code was made ready.
        guard !run.isRunning, !tests.isRunning else {
            taggedInstall?.phase = .failed("Another build was started first. Try again when it has finished.")
            return
        }
        let request = BuildRequest(
            container: source.container, scheme: scheme.name, configuration: project.selectedConfiguration, device: device,
            launches: launchesAfterInstall
        )
        taggedInstall?.request = request
        taggedInstall?.phase = .running
        // Kept apart from the checkout's own builds: it is another folder with another build size.
        let key = Self.taskCountKey(
            project: source.container.url, scheme: request.scheme, configuration: request.configuration, deviceKind: device.kind
        )
        run.start(request, expectedTaskCount: store.taskCount(for: key))
        await run.waitUntilFinished()
        guard run.request == request else { return }
        if run.phase == .succeeded, run.taskCount > 0 { store.setTaskCount(run.taskCount, for: key) }
        recordTaggedInstall(of: build, request: request, project: project.container, commit: source.commit)
        await announceIfInBackground()
        await refreshTaggedSource()
    }

    /// Notes under the real project what is now on the device, so Build mode says so too.
    private func recordTaggedInstall(of build: ReleaseBuild, request: BuildRequest, project: ProjectContainer, commit: String) {
        guard run.phase == .succeeded, let product = run.summary?.product else { return }
        let short = String(commit.prefix(BuildDeskConstants.TaggedSources.shortCommitLength))
        for outcome in run.deviceOutcomes where outcome.succeeded {
            let key = InstallRecord.key(project: project.url, scheme: request.scheme, deviceID: outcome.device.id)
            installRecords[key] = InstallRecord(
                bundleIdentifier: product.bundleIdentifier, configuration: request.configuration, deviceName: outcome.device.name,
                // The build's name stands where a branch would: it says which code this is.
                date: Date(), source: SourceState(branch: build.id, commit: short, hasLocalChanges: false)
            )
        }
    }

    /// Forgets the last tagged install, so its line leaves the window.
    public func dismissTaggedInstall() {
        guard taggedInstall?.phase != .preparing, !(taggedInstall?.phase == .running && run.isRunning) else { return }
        taggedInstall = nil
    }

    // MARK: - The copy on disk

    /// Reads whether a copy of the open project's code exists, and how big it and its build output are.
    public func refreshTaggedSource() async {
        guard let project else { return taggedSource = nil }
        let source = await environment.taggedSources.existing(for: project.container)
        taggedSource = source
        taggedBuildFolder = if let source { await environment.buildFolders.buildFolder(for: source.container) } else { nil }
        // The whole build folder counts: the copy's package checkouts are as big as its build output.
        taggedBuildBytes = if let folder = taggedBuildFolder { await environment.buildFolders.totalBytes(of: folder) } else { nil }
    }

    /// Size of the copy and its build output together; nil when there is no copy.
    public var taggedBytes: Int64? {
        guard let taggedSource else { return nil }
        return (taggedSource.bytes ?? 0) + (taggedBuildBytes ?? 0)
    }

    /// Deletes the copy and what was built from it. The caller asks the person to confirm first.
    public func removeTaggedSource() async {
        guard let source = taggedSource else { return }
        guard !run.isRunning, taggedInstall?.phase != .preparing else {
            return taggedSourceMessage = "Wait for the running build to finish."
        }
        // Xcode keeps files in a build folder open while it is running.
        guard !environment.isXcodeOpen() else { return taggedSourceMessage = "Xcode is open. Quit it first, then remove the files." }
        do {
            let freedBytes = taggedBytes
            // The copy's build folder goes whole, packages included: nothing else uses it.
            if let folder = taggedBuildFolder { try await environment.buildFolders.removeAll(folder) }
            try await environment.taggedSources.remove(source)
            let freed = freedBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "The space"
            taggedSourceMessage = "\(freed) freed."
        } catch {
            taggedSourceMessage = "Couldn't remove the files: \(userMessage(for: error))"
        }
        await refreshTaggedSource()
    }
}

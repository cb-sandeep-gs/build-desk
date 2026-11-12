import BuildDeskCore
import Foundation

// The builddesk command-line tool: the same operations the app offers, for terminals and scripts.

func listSchemes(_ arguments: Arguments) async throws {
    let container = try arguments.container()
    let reader = ProjectReader()
    let snapshot = arguments.has(CLI.Flag.full)
        ? try await reader.fullSnapshot(of: container)
        : try reader.quickSnapshot(of: container)
    if arguments.has(CLI.Flag.json) { return try Output.json(snapshot) }

    Output.table(snapshot.schemes.map { scheme in
        [scheme.name, scheme.kind.rawValue, scheme.buildTargets.map(\.productName).joined(separator: ", ")]
    })
    print("\n\(snapshot.schemes.count) schemes · configurations: \(snapshot.configurations.joined(separator: ", "))")
}

func listTargets(_ arguments: Arguments) throws {
    let snapshot = try ProjectReader().quickSnapshot(of: arguments.container())
    if arguments.has(CLI.Flag.json) { return try Output.json(snapshot.targets) }
    Output.table(snapshot.targets.map { [$0.name, $0.kind.rawValue] })
}

func listDevices(_ arguments: Arguments) async throws {
    let devices = try await DeviceDiscovery().devices()
    if arguments.has(CLI.Flag.json) { return try Output.json(devices) }
    Output.table(devices.map { device in
        let state = switch (device.kind, device.isReady, device.isBooted) {
        case (.physical, true, _): "ready (\(device.connection.rawValue))"
        case (.physical, false, _): device.issue?.title ?? "not ready"
        case (.simulator, _, true): "booted"
        case (.simulator, _, false): "shut down"
        }
        return [device.name, "\(device.platform) \(device.osVersion)", device.kind.rawValue, state, device.id]
    })
}

func run(_ arguments: Arguments) async throws {
    guard !(arguments.has(CLI.Flag.buildOnly) && arguments.has(CLI.Flag.installOnly)) else {
        throw UsageError(message: "\(CLI.Flag.buildOnly) and \(CLI.Flag.installOnly) can't be used together.")
    }
    let container = try arguments.container()
    let scheme = try arguments.required(CLI.Option.scheme)
    let discovery = DeviceDiscovery()
    let device = try await discovery.device(matching: arguments.required(CLI.Option.device))
    let also = try await extraDevices(arguments, discovery)
    // Without an explicit choice, use the project's own default configuration.
    let configuration = try arguments.options[CLI.Option.configuration]
        ?? ProjectReader().quickSnapshot(of: container).defaultConfiguration
        ?? BuildDeskConstants.fallbackConfiguration

    let request = BuildRequest(
        container: container,
        scheme: scheme,
        configuration: configuration,
        device: device,
        additionalDevices: also,
        builds: !arguments.has(CLI.Flag.installOnly),
        installs: !arguments.has(CLI.Flag.buildOnly),
        launches: !arguments.has(CLI.Flag.noLaunch),
        launchOptions: try arguments.launchOptions()
    )
    print("\(scheme) (\(configuration)) → \(device.name)")

    for try await event in BuildPipeline().run(request) {
        report(event)
    }
}

/// The device named by `--also`, if any.
func extraDevices(_ arguments: Arguments, _ discovery: DeviceDiscovery) async throws -> [Device] {
    guard let query = arguments.options[CLI.Option.also] else { return [] }
    return [try await discovery.device(matching: query)]
}

func install(_ arguments: Arguments) async throws {
    let path = try arguments.onlyPositional("app or ipa path")
    let artifact = try await ArtifactReader().read(URL(fileURLWithPath: path))
    let discovery = DeviceDiscovery()
    let devices = [try await discovery.device(matching: arguments.required(CLI.Option.device))]
        + (try await extraDevices(arguments, discovery))
    if let misfit = devices.first(where: { !artifact.fits($0) }) {
        let kind = artifact.isSimulatorBuild ? "a simulator build" : "a device build"
        throw UsageError(message: "\(artifact.name) is \(kind) and can't be installed on \(misfit.name).")
    }
    print("\(artifact.name) \(artifact.version ?? "") (\(artifact.bundleIdentifier)) → \(devices.map(\.name).joined(separator: ", "))")
    let request = InstallRequest(
        artifact: artifact, devices: devices, launches: !arguments.has(CLI.Flag.noLaunch), launchOptions: try arguments.launchOptions()
    )
    for try await event in BuildPipeline().install(request) {
        report(event)
    }
}

func uninstall(_ arguments: Arguments) async throws {
    let bundleIdentifier = try arguments.onlyPositional("bundle identifier")
    let device = try await DeviceDiscovery().device(matching: arguments.required(CLI.Option.device))
    try await DeviceAppService().uninstall(bundleIdentifier: bundleIdentifier, from: device)
    print("Removed \(bundleIdentifier) from \(device.name).")
}

func console(_ arguments: Arguments) async throws {
    let bundleIdentifier = try arguments.onlyPositional("bundle identifier")
    let device = try await DeviceDiscovery().device(matching: arguments.required(CLI.Option.device))
    let options = try arguments.launchOptions()
    for try await line in DeviceAppService().console(bundleIdentifier: bundleIdentifier, on: device, options: options) {
        print(line)
    }
}

func screenshot(_ arguments: Arguments) async throws {
    let device = try await DeviceDiscovery().device(matching: arguments.required(CLI.Option.device))
    let file = URL(fileURLWithPath: try arguments.required(CLI.Option.output))
    try await DeviceToolsService().screenshot(of: device, to: file)
    print("Saved \(file.path)")
}

func appData(_ arguments: Arguments) async throws {
    let bundleIdentifier = try arguments.onlyPositional("bundle identifier")
    let device = try await DeviceDiscovery().device(matching: arguments.required(CLI.Option.device))
    let folder = URL(fileURLWithPath: try arguments.required(CLI.Option.output))
    try await DeviceToolsService().copyAppData(bundleIdentifier: bundleIdentifier, from: device, to: folder)
    print("Copied the data of \(bundleIdentifier) to \(folder.path)")
}

func crashes(_ arguments: Arguments) async throws {
    let process = try arguments.onlyPositional("process name")
    let device = try await DeviceDiscovery().device(matching: arguments.required(CLI.Option.device))
    let tools = DeviceToolsService()
    let logs = try await tools.crashLogs(forProcess: process, on: device)
    guard !logs.isEmpty else { return print("No crash logs for \(process) on \(device.name).") }
    Output.table(logs.map { [$0.name, $0.date?.formatted(date: .abbreviated, time: .shortened) ?? ""] })
    if let output = arguments.options[CLI.Option.output] {
        try await tools.copy(logs, from: device, to: URL(fileURLWithPath: output))
        print("Copied \(logs.count) crash logs to \(output)")
    }
}

/// Raised when tests ran and some failed, so the tool can exit with its own code.
struct TestsFailed: Error {}

func test(_ arguments: Arguments) async throws {
    let container = try arguments.container()
    let scheme = try arguments.required(CLI.Option.scheme)
    let device = try await DeviceDiscovery().device(matching: arguments.required(CLI.Option.device))
    let configuration = try arguments.options[CLI.Option.configuration]
        ?? ProjectReader().quickSnapshot(of: container).defaultConfiguration
        ?? BuildDeskConstants.fallbackConfiguration
    let request = TestRequest(
        container: container, scheme: scheme, configuration: configuration, device: device,
        onlyTesting: arguments.options[CLI.Option.only].map { [$0] } ?? []
    )
    print("Testing \(scheme) (\(configuration)) on \(device.name)")
    for try await event in TestRunner().run(request) {
        switch event {
        case .testingStarted:
            print("==> tests")
        case .caseFinished(let suite, let name, .failed):
            print("    failed: \(suite).\(name)")
        case .finished(let summary):
            try report(summary)
        case .build, .caseFinished:
            break
        }
    }
}

func report(_ summary: TestRunSummary) throws {
    for failed in summary.failed {
        for failure in failed.failures {
            let location = failure.file.map { "\($0):\(failure.line ?? 0): " } ?? ""
            Output.error("\(location)\(failed.suite).\(failed.name): \(failure.message)")
        }
    }
    print("\(summary.count(.passed)) passed, \(summary.count(.failed)) failed, \(summary.count(.skipped)) skipped, "
        + "\(Output.seconds(summary.seconds)) in total")
    if let log = summary.logFile { print("full log: \(log.path)") }
    if !summary.succeeded { throw TestsFailed() }
}

/// Prints one line per thing worth knowing while a run is in progress.
func report(_ event: PipelineEvent) {
    switch event {
    case .stepStarted(let step):
        print("==> \(step.rawValue)")
    case .stepFinished(let step, let seconds):
        print("    \(step.rawValue) done in \(Output.seconds(seconds))")
    case .build(.resolvingPackages):
        print("    resolving packages")
    case .build(.diagnostic(let diagnostic)) where diagnostic.severity == .error:
        // Errors are shown as they happen; warnings are counted in the summary.
        let location = diagnostic.file.map { "\($0):\(diagnostic.line ?? 0): " } ?? ""
        Output.error("    error: \(location)\(diagnostic.message)")
    case .build:
        break
    case .deviceFinished(let outcome):
        print("    \(outcome.device.name): \(outcome.failure.map { "failed. \($0)" } ?? "done")")
    case .finished(let summary):
        report(summary)
    }
}

func report(_ summary: RunSummary) {
    if let product = summary.product { print("installed \(product.bundleIdentifier)") }
    print("\(summary.taskCount) build tasks, \(summary.warnings.count) warnings, \(Output.seconds(summary.totalSeconds)) in total")
    if let log = summary.logFile { print("full log: \(log.path)") }
}

func perform(_ command: CLI.Command, _ arguments: Arguments) async throws {
    switch command {
    case .schemes: try await listSchemes(arguments)
    case .targets: try listTargets(arguments)
    case .devices: try await listDevices(arguments)
    case .run: try await run(arguments)
    case .install: try await install(arguments)
    case .uninstall: try await uninstall(arguments)
    case .console: try await console(arguments)
    case .test: try await test(arguments)
    case .screenshot, .appdata, .crashes: try await performDeviceTool(command, arguments)
    case .release: try await release(arguments)
    }
}

/// `release status <project>` and `release plan <project> …`: the project's release workflow.
func release(_ arguments: Arguments) async throws {
    guard arguments.positionals.count == 2 else { throw UsageError(message: "Give status or plan, then one project path.") }
    let container = try ProjectContainer(url: URL(fileURLWithPath: arguments.positionals[1]))
    guard let provider = try ProjectReader().quickSnapshot(of: container).releaseProvider else {
        throw UsageError(message: "This project's \(ProjectConfig.fileName) has no release section, so it has no release commands.")
    }
    switch arguments.positionals[0] {
    case "status":
        let status = try await ReleaseClient().status(provider)
        if arguments.has(CLI.Flag.json) { return try Output.json(status) }
        for app in status.apps {
            print("\(app.name) \(app.version)")
            Output.table(
                [["  store", app.store?.version ?? "none", app.commitsSinceStore.map { "\($0) commits since" } ?? ""]]
                    + app.tracks.map { ["  \($0.name)", $0.latest?.version ?? "none", $0.commitsSince.map { "\($0) commits since" } ?? ""] }
            )
        }
    case "plan":
        guard let kind = ReleaseAction.Kind(rawValue: try arguments.required(CLI.Option.action)) else {
            throw UsageError(message: "\(CLI.Option.action) is testflight or store.")
        }
        let action = ReleaseAction(
            kind: kind, app: try arguments.required(CLI.Option.app), track: arguments.options[CLI.Option.track],
            branch: arguments.options[CLI.Option.branch], from: arguments.options[CLI.Option.from]
        )
        let plan = try await ReleaseClient().plan(action, provider)
        print(plan.title)
        plan.steps.enumerated().forEach { print("  \($0.offset + 1). \($0.element)") }
        (plan.warnings ?? []).forEach { print("  warning: \($0)") }
        if let notes = plan.notes { print("\nNotes:\n\(notes)") }
    default:
        throw UsageError(message: "release takes status or plan.")
    }
}

/// The commands that fetch something from a device.
func performDeviceTool(_ command: CLI.Command, _ arguments: Arguments) async throws {
    switch command {
    case .screenshot: try await screenshot(arguments)
    case .appdata: try await appData(arguments)
    case .crashes: try await crashes(arguments)
    default: break
    }
}

func main() async -> Int32 {
    var raw = Array(CommandLine.arguments.dropFirst())
    guard let name = raw.first, let command = CLI.Command(rawValue: name) else {
        print(CLI.usage)
        return raw.isEmpty ? 0 : CLI.ExitCode.usage
    }
    raw.removeFirst()
    do {
        try await perform(command, Arguments(raw))
        return 0
    } catch is TestsFailed {
        return CLI.ExitCode.testsFailed
    } catch let error as UsageError {
        Output.error("\(error.message)\n\n\(CLI.usage)")
        return CLI.ExitCode.usage
    } catch {
        Output.error("error: \(error.localizedDescription)")
        // A failed build points at its full log, where the compiler output is.
        if case BuildDeskError.buildFailed(_, let logFile?) = error { Output.error("full log: \(logFile)") }
        return CLI.ExitCode.failure
    }
}

// A stop request (Ctrl-C, or `kill`) cancels the work instead of ending the process outright, so a
// tool that is running (a build, a console attached to a device) is stopped with it and not left behind.
let work = Task { await main() }
let stopSignals = [SIGINT, SIGTERM].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { work.cancel() }
    source.resume()
    return source
}
let status = await work.value
exit(work.isCancelled ? CLI.ExitCode.stopped : status)

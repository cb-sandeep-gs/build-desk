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
        case (.physical, false, _): "not connected"
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
    let device = try await DeviceDiscovery().device(matching: arguments.required(CLI.Option.device))
    // Without an explicit choice, use the project's own default configuration.
    let configuration = try arguments.options[CLI.Option.configuration]
        ?? ProjectReader().quickSnapshot(of: container).defaultConfiguration
        ?? BuildDeskConstants.fallbackConfiguration

    let request = BuildRequest(
        container: container,
        scheme: scheme,
        configuration: configuration,
        device: device,
        builds: !arguments.has(CLI.Flag.installOnly),
        installs: !arguments.has(CLI.Flag.buildOnly),
        launches: !arguments.has(CLI.Flag.noLaunch)
    )
    print("\(scheme) (\(configuration)) → \(device.name)")

    for try await event in BuildPipeline().run(request) {
        report(event)
    }
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
    case .finished(let summary):
        if let product = summary.product { print("installed \(product.bundleIdentifier)") }
        print("\(summary.taskCount) build tasks, \(summary.warnings.count) warnings, \(Output.seconds(summary.totalSeconds)) in total")
        if let log = summary.logFile { print("full log: \(log.path)") }
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
        let arguments = try Arguments(raw)
        switch command {
        case .schemes: try await listSchemes(arguments)
        case .targets: try listTargets(arguments)
        case .devices: try await listDevices(arguments)
        case .run: try await run(arguments)
        }
        return 0
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

exit(await main())

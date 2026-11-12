import BuildDeskCore
import Foundation

/// The words the command line understands. Kept small on purpose: every command is a thin call
/// into BuildDeskCore.
enum CLI {
    enum Command: String, CaseIterable {
        case schemes
        case targets
        case devices
        case run
        case install
        case uninstall
        case console
    }

    enum Option {
        static let scheme = "--scheme"
        static let device = "--device"
        static let configuration = "--configuration"
        static let also = "--also"
        static let launchArguments = "--launch-args"
        static let launchEnvironment = "--launch-env"
        static let launchURL = "--launch-url"
        /// Options that are followed by a value.
        static let withValue: Set<String> = [scheme, device, configuration, also, launchArguments, launchEnvironment, launchURL]
    }

    enum Flag {
        static let json = "--json"
        static let full = "--full"
        static let noLaunch = "--no-launch"
        static let buildOnly = "--build-only"
        static let installOnly = "--install-only"
        static let all: Set<String> = [json, full, noLaunch, buildOnly, installOnly]
    }

    /// Exit codes follow sysexits: 64 is a usage error, 1 a failed operation.
    enum ExitCode {
        static let failure: Int32 = 1
        static let usage: Int32 = 64
        /// 128 + SIGINT, what shells report for a command stopped with Ctrl-C.
        static let stopped: Int32 = 130
    }

    static let usage = """
    builddesk — build, install and launch Xcode schemes without opening Xcode

    Usage:
      builddesk schemes <project> [--full] [--json]
      builddesk targets <project> [--json]
      builddesk devices [--json]
      builddesk run <project> --scheme <name> --device <name-or-udid>
                    [--configuration <name>] [--no-launch] [--build-only | --install-only]
                    [--also <name-or-udid>]
      builddesk install <app-or-ipa> --device <name-or-udid> [--also <name-or-udid>] [--no-launch]
      builddesk uninstall <bundle-id> --device <name-or-udid>
      builddesk console <bundle-id> --device <name-or-udid>

    <project> is a .xcodeproj or .xcworkspace.
      --full          also ask xcodebuild for schemes that have no scheme file (slower)
      --no-launch     install the app but don't open it
      --build-only    build the scheme and stop (frameworks, compile checks)
      --install-only  install the app the last build left behind, without rebuilding
      --also          a second device of the same kind to install the same build on

    How the app is launched (run, install and console):
      --launch-args "<args>"      command-line arguments, separated by spaces
      --launch-env "<N=v N=v>"    environment variables
      --launch-url <link>         a link the app opens at launch

    install puts a built .app or .ipa on a device. console launches an installed app and
    prints what it writes to standard output and error until it exits (Ctrl-C to stop).
    """
}

/// Raised for a command line that cannot be understood; prints the usage text.
struct UsageError: Error {
    let message: String
}

/// A parsed command line: positional values, valued options and flags.
struct Arguments {
    private(set) var positionals: [String] = []
    private(set) var options: [String: String] = [:]
    private(set) var flags: Set<String> = []

    init(_ raw: [String]) throws {
        var iterator = raw.makeIterator()
        while let argument = iterator.next() {
            if CLI.Option.withValue.contains(argument) {
                guard let value = iterator.next() else { throw UsageError(message: "\(argument) needs a value.") }
                options[argument] = value
            } else if CLI.Flag.all.contains(argument) {
                flags.insert(argument)
            } else if argument.hasPrefix("--") {
                throw UsageError(message: "Unknown option \(argument).")
            } else {
                positionals.append(argument)
            }
        }
    }

    func has(_ flag: String) -> Bool { flags.contains(flag) }

    func required(_ option: String) throws -> String {
        guard let value = options[option] else { throw UsageError(message: "\(option) is required.") }
        return value
    }

    /// The single positional value of commands that take one (a file path or a bundle identifier).
    func onlyPositional(_ what: String) throws -> String {
        guard positionals.count == 1 else { throw UsageError(message: "Give one \(what).") }
        return positionals[0]
    }

    /// What `--launch-args`, `--launch-env` and `--launch-url` add up to.
    func launchOptions() throws -> LaunchOptions {
        do {
            return try LaunchOptions.parse(
                arguments: options[CLI.Option.launchArguments] ?? "",
                environment: options[CLI.Option.launchEnvironment] ?? "",
                url: options[CLI.Option.launchURL] ?? ""
            )
        } catch let error as LaunchOptions.ParseError {
            throw UsageError(message: error.message)
        }
    }

    /// The project path every project command takes as its only positional value.
    func container() throws -> ProjectContainer {
        guard positionals.count == 1 else { throw UsageError(message: "Give one project path.") }
        // Resolve against the current folder so relative paths work.
        return try ProjectContainer(url: URL(fileURLWithPath: positionals[0]))
    }
}

/// Plain-text output helpers.
enum Output {
    static func json(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    /// Prints rows as left-aligned columns sized to their widest cell.
    static func table(_ rows: [[String]]) {
        let columnCount = rows.map(\.count).max() ?? 0
        let widths = (0..<columnCount).map { column in
            rows.map { $0.count > column ? $0[column].count : 0 }.max() ?? 0
        }
        for row in rows {
            let cells = row.enumerated().map { index, cell in
                // The last column is not padded, so lines carry no trailing spaces.
                index == row.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }
            print(cells.joined(separator: "  "))
        }
    }

    static func error(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func seconds(_ value: Double) -> String {
        String(format: "%.1f s", value)
    }
}

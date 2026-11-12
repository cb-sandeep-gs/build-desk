import Foundation

/// Turns `xcodebuild` build output into events, one line at a time.
///
/// This is the one place Build Desk reads text meant for people: a build has no machine-readable
/// progress output. Only stable, long-standing line shapes are recognised, and an unrecognised
/// line is simply not an event, so a new Xcode can at worst show less progress, never break a build.
public struct BuildOutputParser: Sendable {
    private enum Marker {
        static let resolvePackages = "Resolve Package Graph"
        static let succeeded = "** BUILD SUCCEEDED **"
        static let failed = "** BUILD FAILED **"
        static let targetOpen = " (in target '"
        static let targetClose = "' from project '"
    }

    public init() {}

    public func parse(_ line: String) -> BuildEvent? {
        switch line {
        case Marker.resolvePackages: return .resolvingPackages
        case Marker.succeeded: return .outcome(succeeded: true)
        case Marker.failed: return .outcome(succeeded: false)
        default: break
        }
        if let diagnostic = diagnostic(in: line) { return .diagnostic(diagnostic) }
        return task(in: line)
    }

    /// "SwiftCompile normal arm64 /path/File.swift (in target 'Sample' from project 'Sample')".
    private func task(in line: String) -> BuildEvent? {
        guard let first = line.first, first.isUppercase,
              let open = line.range(of: Marker.targetOpen, options: .backwards),
              let close = line.range(of: Marker.targetClose, range: open.upperBound..<line.endIndex) else { return nil }
        let name = line.prefix { !$0.isWhitespace }
        return .task(name: String(name), target: String(line[open.upperBound..<close.lowerBound]))
    }

    /// "/path/File.swift:41:13: warning: message", or "error: message" with no location.
    private func diagnostic(in line: String) -> Diagnostic? {
        for severity in Diagnostic.Severity.allCases {
            let marker = "\(severity.rawValue): "
            if line.hasPrefix(marker) {
                return Diagnostic(severity: severity, message: String(line.dropFirst(marker.count)))
            }
            // A located diagnostic starts with an absolute path; this skips ordinary output that
            // happens to contain "warning: " in the middle of a sentence.
            guard line.hasPrefix("/"), let range = line.range(of: ": \(marker)") else { continue }
            let message = String(line[range.upperBound...])
            let location = line[..<range.lowerBound].split(separator: ":", omittingEmptySubsequences: false)
            // path:line:column — but a path may itself contain a colon, so read from the end.
            guard location.count >= 3,
                  let column = Int(location[location.count - 1]),
                  let lineNumber = Int(location[location.count - 2]) else {
                return Diagnostic(severity: severity, message: message, file: String(line[..<range.lowerBound]))
            }
            let file = location.dropLast(2).joined(separator: ":")
            return Diagnostic(severity: severity, message: message, file: file, line: lineNumber, column: column)
        }
        return nil
    }
}

/// Reads `xcodebuild -showBuildSettings -json` to find the app a scheme built.
enum BuildSettingsParser {
    private static let applicationProductType = "com.apple.product-type.application"

    private struct Entry: Decodable {
        let buildSettings: [String: String]
    }

    private enum Key {
        static let productType = "PRODUCT_TYPE"
        static let buildFolder = "TARGET_BUILD_DIR"
        static let wrapperName = "WRAPPER_NAME"
        static let bundleIdentifier = "PRODUCT_BUNDLE_IDENTIFIER"
    }

    /// A scheme can build several targets (extensions, a watch app); the one to install is the
    /// first application product.
    static func product(in data: Data, scheme: String) throws -> BuiltProduct {
        let entries: [Entry]
        do {
            entries = try JSONDecoder().decode([Entry].self, from: data)
        } catch {
            throw BuildDeskError.unexpectedOutput(tool: "xcodebuild -showBuildSettings", reason: error.localizedDescription)
        }
        for settings in entries.map(\.buildSettings) where settings[Key.productType] == applicationProductType {
            guard let folder = settings[Key.buildFolder],
                  let wrapper = settings[Key.wrapperName],
                  let bundleIdentifier = settings[Key.bundleIdentifier] else { continue }
            return BuiltProduct(
                appURL: URL(fileURLWithPath: folder).appendingPathComponent(wrapper),
                bundleIdentifier: bundleIdentifier
            )
        }
        throw BuildDeskError.noApplicationProduct(scheme: scheme)
    }
}

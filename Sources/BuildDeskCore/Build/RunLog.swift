import Foundation

/// The full output of one run, written to disk as it arrives. The UI shows a filtered view; this
/// file is the complete record for when something needs a closer look.
public actor RunLog {
    private typealias Logs = BuildDeskConstants.Logs

    public nonisolated let url: URL
    private let handle: FileHandle

    /// `~/Library/Logs/BuildDesk`, where Console and other Mac tools expect app logs.
    public static var defaultDirectory: URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs")
            .appendingPathComponent(Logs.folderName)
    }

    /// Creates the log file for a new run and deletes the oldest logs beyond the kept count.
    public init(directory: URL, scheme: String, date: Date = Date()) throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.removeOldLogs(in: directory, keeping: Logs.keptRuns - 1)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        // A scheme name can contain spaces or slashes; keep the file name plain.
        let safeScheme = scheme.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        url = directory.appendingPathComponent("\(formatter.string(from: date))-\(String(safeScheme)).\(Logs.fileExtension)")
        files.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    public func append(_ line: String) {
        // A full disk must not stop the build; the log is a convenience.
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    public func close() {
        try? handle.close()
    }

    private static func removeOldLogs(in directory: URL, keeping kept: Int) {
        let files = FileManager.default
        let logs = ((try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == Logs.fileExtension }
            // Names start with a timestamp, so name order is age order.
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in logs.dropFirst(max(kept, 0)) { try? files.removeItem(at: old) }
    }
}

import BuildDeskCore
import Foundation
import Observation

/// What an app prints while it runs on a device, as a bounded, filterable list of lines.
@MainActor
@Observable
public final class ConsoleModel {
    /// One printed line. The number keeps lines distinct when the same text is printed twice.
    public struct Line: Identifiable, Equatable, Sendable {
        public let id: Int
        public let text: String
    }

    /// Lines kept in memory; older ones are dropped. A chatty app prints thousands a minute.
    public static let lineLimit = 2_000

    public private(set) var lines: [Line] = []
    public private(set) var isRunning = false
    /// The app and device the console is, or was last, attached to.
    public private(set) var title: String?
    /// Why the console ended, when it ended with a failure.
    public private(set) var failure: String?
    /// Only lines containing this text are shown.
    public var filter = ""

    private let service: any DeviceAppManaging
    private var task: Task<Void, Never>?
    private var nextID = 0

    public init(service: any DeviceAppManaging) {
        self.service = service
    }

    public var visibleLines: [Line] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? lines : lines.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    /// True once there is something to show, so the view knows to appear.
    public var isVisible: Bool { isRunning || !lines.isEmpty || failure != nil }

    /// Launches the app attached to its output. A console that is already running is replaced.
    public func start(bundleIdentifier: String, on device: Device, options: LaunchOptions = LaunchOptions()) {
        stop()
        lines = []
        failure = nil
        title = "\(bundleIdentifier) on \(device.name)"
        isRunning = true
        let output = service.console(bundleIdentifier: bundleIdentifier, on: device, options: options)
        task = Task { [weak self] in
            do {
                for try await line in output { self?.append(line) }
            } catch is CancellationError {
                // Stopped by the user.
            } catch {
                if !Task.isCancelled { self?.failure = userMessage(for: error) }
            }
            self?.isRunning = false
        }
    }

    /// Detaches from the app. The app keeps running on the device.
    public func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    public func clear() {
        lines = []
        failure = nil
    }

    /// Lets tests wait for the output to end.
    public func waitUntilFinished() async {
        await task?.value
    }

    private func append(_ text: String) {
        lines.append(Line(id: nextID, text: text))
        nextID += 1
        if lines.count > Self.lineLimit { lines.removeFirst(lines.count - Self.lineLimit) }
    }
}

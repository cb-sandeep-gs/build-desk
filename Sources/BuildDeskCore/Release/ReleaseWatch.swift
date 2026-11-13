import Foundation

/// Something that changed on the store's side between two readings of it.
public struct ReleaseChange: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case cloudSucceeded
        case cloudFailed
        /// The build got a testing state; the text is the store's, such as "In testing".
        case reachedTesters(String)
    }

    /// The id of the app the build belongs to.
    public let app: String
    /// The id of the build, the same as in the status.
    public let build: String
    public let kind: Kind

    public init(app: String, build: String, kind: Kind) {
        self.app = app
        self.build = build
        self.kind = kind
    }
}

/// Compares two readings of the store and decides how soon to read it again.
public enum ReleaseWatch {
    /// What happened between two readings. Only steps a person waits for are reported: a cloud
    /// build that ended and a build that reached testers.
    ///
    /// A reading that follows "not connected" reports nothing, because every build would look new.
    public static func changes(from old: ReleaseStoreStatus, to new: ReleaseStoreStatus) -> [ReleaseChange] {
        guard old.connected, new.connected else { return [] }
        var changes: [ReleaseChange] = []
        for app in new.apps {
            // An app the earlier reading did not have has no "before" to compare with.
            guard let before = old.apps.first(where: { $0.id == app.id }) else { continue }
            for build in app.builds {
                let earlier = before.builds.first { $0.id == build.id }
                if let kind = change(from: earlier, to: build) {
                    changes.append(ReleaseChange(app: app.id, build: build.id, kind: kind))
                }
            }
        }
        return changes
    }

    /// The one thing worth saying about a build, or nil. Reaching testers says more than the
    /// cloud build ending, so it wins when both happened between two readings.
    private static func change(from earlier: ReleaseStoreBuild?, to build: ReleaseStoreBuild) -> ReleaseChange.Kind? {
        guard let earlier else {
            // A build that started and failed between two readings is still worth a word.
            return build.cloudState == .failed ? .cloudFailed : nil
        }
        if earlier.testing == nil, let testing = build.testing { return .reachedTesters(testing) }
        guard earlier.cloudState == .running else { return nil }
        switch build.cloudState {
        case .succeeded: return .cloudSucceeded
        case .failed: return .cloudFailed
        case .running, nil: return nil
        }
    }

    /// True while a cloud build is running or a finished one has not reached testers yet.
    public static func isWaiting(_ status: ReleaseStoreStatus?) -> Bool {
        guard let status, status.connected else { return false }
        return status.apps.contains { $0.builds.contains { $0.cloudState == .running } }
    }

    /// How long to wait before the next reading: short while a cloud build is running, long otherwise.
    public static func interval(after status: ReleaseStoreStatus?) -> TimeInterval {
        isWaiting(status) ? BuildDeskConstants.ReleaseWatch.activeSeconds : BuildDeskConstants.ReleaseWatch.idleSeconds
    }
}

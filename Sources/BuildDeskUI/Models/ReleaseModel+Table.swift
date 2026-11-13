import BuildDeskCore
import Foundation

/// Which builds the Release table shows.
public enum ReleaseBuildFilter: Hashable, Sendable {
    case all
    /// One track, by its id.
    case track(String)
    /// Builds whose cloud build failed.
    case failed
}

/// The builds of one app version, such as every build of 27.05.
public struct ReleaseBuildGroup: Identifiable, Equatable, Sendable {
    /// The version the builds share: the first two parts of a build's version.
    public let id: String
    public let builds: [ReleaseBuild]
    /// True when this version is the one on the store.
    public let isOnStore: Bool
}

extension ReleaseBuild {
    /// A version has two parts; a build adds a third.
    private static let appVersionParts = 2

    /// "27.05" for "27.05.03": the app version a build belongs to.
    var appVersion: String {
        version.split(separator: ".").prefix(Self.appVersionParts).joined(separator: ".")
    }
}

extension ReleaseModel {
    /// The filters offered: all, one per track of the selected app, and failed when the store is known.
    public var filters: [ReleaseBuildFilter] {
        let tracks = (selectedApp?.tracks ?? []).map { ReleaseBuildFilter.track($0.id) }
        // One track needs no filter of its own.
        return [.all] + (tracks.count > 1 ? tracks : []) + (store.value?.connected == true ? [.failed] : [])
    }

    public func title(of filter: ReleaseBuildFilter) -> String {
        switch filter {
        case .all: "All"
        case .track(let id): selectedApp?.tracks.first { $0.id == id }?.name ?? id
        case .failed: "Failed"
        }
    }

    /// The selected app's builds that pass the filter, newest first.
    public var filteredBuilds: [ReleaseBuild] {
        builds.filter { build in
            switch filter {
            case .all: true
            case .track(let id): build.track == id
            case .failed: storeBuild(for: build)?.cloudState == .failed
            }
        }
    }

    /// The filtered builds under their app version, in the order the versions first appear.
    public var buildGroups: [ReleaseBuildGroup] {
        let storeVersion = selectedApp?.store?.appVersion
        var order: [String] = []
        var byVersion: [String: [ReleaseBuild]] = [:]
        for build in filteredBuilds {
            let version = build.appVersion
            if byVersion[version] == nil { order.append(version) }
            byVersion[version, default: []].append(build)
        }
        return order.map { ReleaseBuildGroup(id: $0, builds: byVersion[$0] ?? [], isOnStore: $0 == storeVersion) }
    }

    /// The build whose details the inspector shows.
    public var selectedBuild: ReleaseBuild? {
        builds.first { $0.id == selectedBuildID }
    }

    /// A build's state in a few words: the store's when it is known, else what kind of build it is.
    public func stateText(of build: ReleaseBuild) -> String {
        if let text = storeBuild(for: build)?.stateText, !text.isEmpty { return text }
        return build.kind == .store ? "Store release" : ""
    }

    /// Starts marking this build as the one that shipped. Nothing happens until the plan is confirmed.
    public func beginStoreRelease(of build: ReleaseBuild) {
        begin(.store)
        guard build.kind == .testflight, let action = activeAction else { return }
        action.action.from = build.id
    }
}

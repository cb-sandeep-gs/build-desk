import BuildDeskCore
import Foundation
import Observation

/// Schemes of one kind, as one section of the scheme list.
public struct SchemeGroup: Equatable, Identifiable, Sendable {
    public let kind: SchemeKind
    public let schemes: [Scheme]

    public var id: SchemeKind { kind }

    public var title: String {
        switch kind {
        case .app: "Apps"
        case .appExtension: "Extensions"
        case .framework: "Frameworks"
        case .tests: "Tests"
        case .other: "Other"
        }
    }
}

/// One open project: its schemes, the selected scheme and configuration.
@MainActor
@Observable
public final class ProjectModel {
    /// The order of the sections in the scheme list: what can be installed comes first.
    private static let groupOrder: [SchemeKind] = [.app, .appExtension, .framework, .tests, .other]

    public let container: ProjectContainer
    public private(set) var state: LoadState<ProjectSnapshot> = .idle
    /// True while the slower full scheme listing (through `xcodebuild`) is running.
    public private(set) var isLoadingAllSchemes = false
    /// Set once the full listing has been merged in; the list then has nothing more to load.
    public private(set) var hasAllSchemes = false
    public private(set) var allSchemesError: String?

    /// Text typed in the filter field of the scheme list.
    public var filter = ""
    public var selectedSchemeName: String? {
        didSet { store.setLastScheme(selectedSchemeName, for: container.url) }
    }
    public var selectedConfiguration: String = BuildDeskConstants.fallbackConfiguration {
        didSet { store.setLastConfiguration(selectedConfiguration, for: container.url) }
    }

    private let reader: any ProjectReading
    private let store: PreferenceStore
    private var hasChosenConfiguration = false

    public init(container: ProjectContainer, reader: any ProjectReading, store: PreferenceStore) {
        self.container = container
        self.reader = reader
        self.store = store
    }

    public var snapshot: ProjectSnapshot? { state.value }

    public var selectedScheme: Scheme? {
        selectedSchemeName.flatMap { snapshot?.scheme(named: $0) }
    }

    /// The scheme list as sections, narrowed by the filter text. Empty sections are left out.
    public var groups: [SchemeGroup] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        let schemes = (snapshot?.schemes ?? []).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        return Self.groupOrder.compactMap { kind in
            let matching = schemes.filter { $0.kind == kind }
            return matching.isEmpty ? nil : SchemeGroup(kind: kind, schemes: matching)
        }
    }

    /// Reads the project's own files. Fast, but still done off the main thread: a project file can
    /// be several megabytes.
    public func load() async {
        if snapshot == nil { state = .loading }
        do {
            let (reader, container) = (reader, container)
            let snapshot = try await Task.detached { try reader.quickSnapshot(of: container) }.value
            apply(snapshot)
        } catch {
            state = .failed(userMessage(for: error))
        }
    }

    /// Adds the schemes only `xcodebuild` knows (Swift package schemes). Slow, so it runs only
    /// when asked for.
    public func loadAllSchemes() async {
        guard !isLoadingAllSchemes else { return }
        isLoadingAllSchemes = true
        allSchemesError = nil
        defer { isLoadingAllSchemes = false }
        do {
            apply(try await reader.fullSnapshot(of: container))
            hasAllSchemes = true
        } catch {
            // The quick list stays usable; only say why the rest is missing.
            allSchemesError = userMessage(for: error)
        }
    }

    private func apply(_ snapshot: ProjectSnapshot) {
        state = .loaded(snapshot)
        let remembered = selectedSchemeName ?? store.lastScheme(for: container.url)
        if let remembered, snapshot.scheme(named: remembered) != nil {
            if selectedSchemeName != remembered { selectedSchemeName = remembered }
        } else {
            // Nothing remembered, or it is gone: start on an app, since installing one is what the
            // window is for; an extension that happens to sort first is not a good starting point.
            let schemes = snapshot.schemes
            selectedSchemeName = (schemes.first { $0.kind == .app } ?? schemes.first { $0.isInstallable } ?? schemes.first)?.name
        }
        // The first snapshot picks the starting configuration; a reload keeps the user's choice
        // unless the project no longer has it.
        if !hasChosenConfiguration || !snapshot.configurations.contains(selectedConfiguration) {
            selectedConfiguration = Self.startingConfiguration(snapshot, remembered: store.lastConfiguration(for: container.url))
            hasChosenConfiguration = true
        }
    }

    /// The remembered configuration, else Debug (what a development install wants), else the
    /// project's own default, else whatever comes first.
    private static func startingConfiguration(_ snapshot: ProjectSnapshot, remembered: String?) -> String {
        let candidates = [remembered, BuildDeskConstants.fallbackConfiguration, snapshot.defaultConfiguration]
        return candidates.compactMap { $0 }.first { snapshot.configurations.contains($0) }
            ?? snapshot.configurations.first
            ?? BuildDeskConstants.fallbackConfiguration
    }
}

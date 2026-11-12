import BuildDeskCore
import Foundation
import Observation

/// One section of the scheme list: the project's favorites, or the schemes of one kind.
public struct SchemeGroup: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let schemes: [Scheme]

    /// The schemes a project's `.builddesk.json` lists first.
    static func favorites(_ schemes: [Scheme]) -> SchemeGroup {
        SchemeGroup(id: "favorites", title: "Favorites", schemes: schemes)
    }

    static func kind(_ kind: SchemeKind, _ schemes: [Scheme]) -> SchemeGroup {
        let title = switch kind {
        case .app: "Apps"
        case .appExtension: "Extensions"
        case .framework: "Frameworks"
        case .tests: "Tests"
        case .other: "Other"
        }
        return SchemeGroup(id: kind.rawValue, title: title, schemes: schemes)
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
    /// Also list the schemes the project's `.builddesk.json` hides.
    public var showsHiddenSchemes = false
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
        guard let snapshot else { return [] }
        let query = filter.trimmingCharacters(in: .whitespaces)
        let schemes = snapshot.schemes.filter { scheme in
            (query.isEmpty || scheme.name.localizedCaseInsensitiveContains(query))
                && (showsHiddenSchemes || !snapshot.config.hides(scheme.name))
        }
        // Favorites come first, in the order the project lists them, and are not repeated below.
        let favorites = snapshot.config.favoriteSchemes.compactMap { name in schemes.first { $0.name == name } }
        let others = schemes.filter { scheme in !favorites.contains { $0.name == scheme.name } }
        let byKind = Self.groupOrder.compactMap { kind -> SchemeGroup? in
            let matching = others.filter { $0.kind == kind }
            return matching.isEmpty ? nil : .kind(kind, matching)
        }
        return (favorites.isEmpty ? [] : [.favorites(favorites)]) + byKind
    }

    /// How many schemes the project's `.builddesk.json` hides.
    public var hiddenSchemeCount: Int {
        guard let snapshot else { return 0 }
        return snapshot.schemes.filter { snapshot.config.hides($0.name) }.count
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
            selectedSchemeName = Self.startingScheme(snapshot)?.name
        }
        // The first snapshot picks the starting configuration; a reload keeps the user's choice
        // unless the project no longer has it.
        if !hasChosenConfiguration || !snapshot.configurations.contains(selectedConfiguration) {
            selectedConfiguration = Self.startingConfiguration(snapshot, remembered: store.lastConfiguration(for: container.url))
            hasChosenConfiguration = true
        }
    }

    /// Nothing remembered, or it is gone: what the project asks for, else its first favorite, else
    /// an app, since installing one is what the window is for; an extension that happens to sort
    /// first is not a good starting point.
    private static func startingScheme(_ snapshot: ProjectSnapshot) -> Scheme? {
        let schemes = snapshot.schemes
        let asked = ([snapshot.config.defaultScheme] + snapshot.config.favoriteSchemes).compactMap { $0 }
        return asked.lazy.compactMap { snapshot.scheme(named: $0) }.first
            ?? schemes.first { $0.kind == .app }
            ?? schemes.first { $0.isInstallable }
            ?? schemes.first
    }

    /// The remembered configuration, else the one the project's `.builddesk.json` asks for, else
    /// Debug (what a development install wants), else Xcode's default, else whatever comes first.
    private static func startingConfiguration(_ snapshot: ProjectSnapshot, remembered: String?) -> String {
        let candidates = [
            remembered, snapshot.config.defaultConfiguration, BuildDeskConstants.fallbackConfiguration, snapshot.defaultConfiguration,
        ]
        return candidates.compactMap { $0 }.first { snapshot.configurations.contains($0) }
            ?? snapshot.configurations.first
            ?? BuildDeskConstants.fallbackConfiguration
    }
}

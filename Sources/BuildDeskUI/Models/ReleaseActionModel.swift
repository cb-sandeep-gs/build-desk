import BuildDeskCore
import Foundation
import Observation

/// Where a confirmed release action stands.
public enum ReleaseRunState: Equatable, Sendable {
    case idle
    case running
    case done(ReleaseResult)
    case failed(String)
}

/// One release action from the first click to its result: the inputs the person chooses, the plan
/// the project answers with, and the run after the plan is confirmed.
@MainActor
@Observable
public final class ReleaseActionModel {
    /// What the person has chosen. Any change throws the plan away: a plan is only ever
    /// confirmed for exactly the inputs it was made for.
    public var action: ReleaseAction {
        didSet {
            guard action != oldValue, runState != .running else { return }
            plan = .idle
            runState = .idle
        }
    }
    public private(set) var plan: LoadState<ReleasePlan> = .idle
    public private(set) var runState: ReleaseRunState = .idle

    public let app: ReleaseApp
    /// For an action on an existing build: that build.
    public private(set) var build: ReleaseBuild?
    /// Test builds of the app that a store release can be made from, newest first.
    public let shippedCandidates: [ReleaseBuild]
    public let branches: [String]
    /// The branch of the checkout, shown as what "this checkout" means.
    public let checkoutBranch: String?

    private let provider: ReleaseProvider
    private let client: any ReleaseProviding

    init(kind: ReleaseAction.Kind, app: ReleaseApp, status: ReleaseStatus, provider: ReleaseProvider, client: any ReleaseProviding) {
        self.app = app
        self.provider = provider
        self.client = client
        shippedCandidates = status.builds.filter { $0.app == app.id && $0.kind == .testflight }
        branches = status.branches ?? []
        checkoutBranch = status.head?.branch
        switch kind {
        // Start on the first track and the newest test build: the usual choice, one click from a plan.
        case .testflight: action = ReleaseAction(kind: .testflight, app: app.id, track: app.tracks.first?.id)
        case .store: action = ReleaseAction(kind: .store, app: app.id, from: shippedCandidates.first?.id)
        // An action on an existing build is started with that build (the other initializer).
        case .notes, .testers: action = ReleaseAction(kind: kind, app: app.id)
        }
    }

    /// An action on a build that already exists: its notes for testers, or its tester group.
    init(
        kind: ReleaseAction.Kind, build: ReleaseBuild, app: ReleaseApp, status: ReleaseStatus, provider: ReleaseProvider,
        client: any ReleaseProviding
    ) {
        self.app = app
        self.provider = provider
        self.client = client
        self.build = build
        shippedCandidates = []
        branches = []
        checkoutBranch = status.head?.branch
        action = ReleaseAction(kind: kind, app: app.id, build: build.id)
    }

    public var title: String {
        switch action.kind {
        case .testflight: "New test build of \(app.name)"
        case .store: "Store release of \(app.name)"
        case .notes: "What to test in \(build?.version ?? app.name)"
        case .testers: "Add \(build?.version ?? "this build") to testers"
        }
    }

    /// What the confirm button says: it names what the click does.
    public func confirmTitle(for plan: ReleasePlan) -> String {
        switch action.kind {
        case .testflight, .store: "Create \(plan.title)"
        case .notes: "Save Notes"
        case .testers: "Add to Testers"
        }
    }

    public var selectedTrack: ReleaseTrack? {
        app.tracks.first { $0.id == action.track }
    }

    /// True when the person has to write the notes of the build themselves.
    public var needsWrittenNotes: Bool {
        action.kind == .testflight && selectedTrack?.notes == .written
    }

    /// What is still missing before a plan can be asked for; nil when nothing is.
    public var problem: String? {
        switch action.kind {
        case .testflight:
            guard selectedTrack != nil else { return "Choose a track." }
            if needsWrittenNotes, (action.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Write the notes for this build; this track's notes are not generated."
            }
        case .store:
            guard action.from != nil else { return "Choose the test build that was shipped." }
        case .notes:
            if (action.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Write what testers should look at in this build."
            }
        case .testers:
            break
        }
        return nil
    }

    public var canConfirm: Bool {
        plan.value != nil && runState != .running && !isDone
    }

    public var isDone: Bool {
        if case .done = runState { return true }
        return false
    }

    /// Asks the project what the action would do. Nothing is changed.
    public func preview() async {
        guard problem == nil, plan != .loading, runState != .running else { return }
        let asked = action
        plan = .loading
        do {
            let answer = try await client.plan(asked, provider)
            // The person changed something while the project was answering: this plan is for old inputs.
            guard asked == action else { return }
            plan = .loaded(answer)
        } catch {
            guard asked == action else { return }
            plan = .failed(userMessage(for: error))
        }
    }

    /// Does what the plan on screen describes. Called only from the confirm button.
    public func confirm() async {
        guard canConfirm, let confirmed = plan.value else { return }
        runState = .running
        do {
            runState = .done(try await client.run(action, confirming: confirmed, provider))
        } catch {
            // A refusal (for example, the code moved) means the plan is no longer true: ask again.
            runState = .failed(userMessage(for: error))
            plan = .idle
        }
    }
}

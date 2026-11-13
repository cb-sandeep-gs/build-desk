import BuildDeskCore
import Foundation

/// A copy of the demo project's code, as if a tagged build had been made before.
struct DemoTaggedSources: TaggedSourcePreparing {
    private static let bytes: Int64 = 310_000_000

    private func source(for container: ProjectContainer) -> TaggedSource {
        TaggedSource(container: container, folder: URL(fileURLWithPath: "/Users/you/Library/Caches/BuildDesk/TaggedSources/Harbor"),
                     commit: "a41c9e2f7b3d", bytes: Self.bytes)
    }

    func prepare(commit: String, of container: ProjectContainer) async throws -> TaggedSource { source(for: container) }
    func existing(for container: ProjectContainer) async -> TaggedSource? { source(for: container) }
    func remove(_ source: TaggedSource) async throws {}
}

struct DemoRelease: ReleaseProviding {
    private static let day: Double = 24 * 60 * 60

    func status(_ provider: ReleaseProvider) async throws -> ReleaseStatus {
        let now = Date().timeIntervalSince1970
        func build(_ id: String, _ track: String?, _ version: String, daysAgo: Double, notes: String) -> ReleaseBuild {
            ReleaseBuild(
                id: id, app: "harbor", track: track, kind: track == nil ? .store : .testflight, version: version,
                commit: "a41c9e2f7b3d", date: now - daysAgo * Self.day, branch: track == nil ? nil : "develop", notes: notes,
                from: track == nil ? "HarborInternal-4.1.9" : nil
            )
        }
        let internalLatest = build("HarborInternal-4.2.3", "internal", "4.2.3", daysAgo: 1, notes: "Faster catalog search")
        let partnerLatest = build("HarborPartner-4.2.1", "partner", "4.2.1", daysAgo: 6, notes: "Build for payment partners")
        let store = build("HarborStore-4.1", nil, "4.1", daysAgo: 9, notes: "Harbor 4.1")
        return ReleaseStatus(
            head: ReleaseHead(branch: "develop", commit: "a41c9e2f7b3d", subject: "Fix the cart total", dirty: false),
            apps: [
                ReleaseApp(
                    id: "harbor", name: "Harbor", version: "4.2",
                    tracks: [
                        ReleaseTrack(id: "internal", name: "Internal testers", latest: internalLatest, commitsSince: 14, notes: .generated),
                        ReleaseTrack(id: "partner", name: "Partners", latest: partnerLatest, commitsSince: 31, notes: .written),
                    ],
                    store: store, commitsSinceStore: 120, scheme: "Harbor"
                ),
                ReleaseApp(
                    id: "harbor-pro", name: "Harbor Pro", version: "2.0", tracks: [ReleaseTrack(id: "internal", name: "Internal testers")]
                ),
            ],
            builds: [
                internalLatest,
                build("HarborInternal-4.2.2", "internal", "4.2.2", daysAgo: 3, notes: "Cart total with discounts"),
                partnerLatest,
                build("HarborInternal-4.2.1", "internal", "4.2.1", daysAgo: 8, notes: "First build of 4.2"),
                store,
            ],
            branches: ["develop", "main", "feature/checkout"], buildActions: ["notes", "testers"]
        )
    }

    func plan(_ action: ReleaseAction, _ provider: ReleaseProvider) async throws -> ReleasePlan {
        ReleasePlan(
            title: "HarborInternal-4.2.4",
            steps: ["Create tag HarborInternal-4.2.4 on a41c9e2 (develop)", "Write the notes below into the tag",
                    "Push the tag, which starts the cloud build"],
            notes: "Changes in this build\n- Faster catalog search\n- Cart total with discounts\n- Fix the cart total",
            commit: "a41c9e2f7b3d"
        )
    }

    func run(_ action: ReleaseAction, confirming plan: ReleasePlan, _ provider: ReleaseProvider) async throws -> ReleaseResult {
        ReleaseResult(result: plan.title, done: ["Created tag \(plan.title)", "Pushed the tag"])
    }

    func artifact(of build: ReleaseBuild, to folder: URL, _ provider: ReleaseProvider) async throws -> ReleaseArtifact {
        ReleaseArtifact(file: folder.appendingPathComponent("\(build.id)-ad-hoc.ipa").path, kind: "ad-hoc", bytes: 61_000_000)
    }

    func details(of build: ReleaseBuild, _ provider: ReleaseProvider) async throws -> ReleaseBuildDetails {
        let lines = [
            "Changes in this build", "- \(build.notes ?? "Fixes")", "- Smaller images on the product page", "- Fix a crash on an empty cart",
        ]
        let notes = lines.joined(separator: "\n")
        return ReleaseBuildDetails(id: build.id, notes: notes, testerNotes: "Please try the cart with a discount code.")
    }

    func checks(_ provider: ReleaseProvider) async throws -> ReleaseChecks {
        ReleaseChecks(
            isGo: false,
            gates: [
                ReleaseGate(title: "Generated files are current", passed: true, seconds: 4),
                ReleaseGate(title: "No known security issues in packages", passed: false, seconds: 21),
                ReleaseGate(title: "Documents match the code", passed: true, seconds: 3),
                ReleaseGate(title: "Style rules", passed: false, blocking: false, seconds: 9),
            ],
            hint: "Fix: No known security issues in packages. Update the package named in the scan."
        )
    }

    func store(_ provider: ReleaseProvider) async throws -> ReleaseStoreStatus {
        ReleaseStoreStatus(connected: true, apps: [
            ReleaseStoreApp(
                id: "harbor",
                builds: [
                    ReleaseStoreBuild(id: "HarborInternal-4.2.3", number: "812", cloud: "running", cloudDetail: "Release workflow"),
                    ReleaseStoreBuild(id: "HarborInternal-4.2.2", number: "811", cloud: "succeeded", cloudDetail: "Release workflow",
                                      testing: "In testing", groups: ["Staff"]),
                    ReleaseStoreBuild(id: "HarborPartner-4.2.1", number: "809", cloud: "succeeded", cloudDetail: "Partner workflow",
                                      testing: "In testing", groups: ["Payment partners"]),
                    ReleaseStoreBuild(id: "HarborInternal-4.2.1", number: "805", cloud: "failed", cloudDetail: "Release workflow"),
                ],
                storeVersions: [ReleaseStoreVersion(version: "4.2", state: "Prepare for submission")]
            ),
        ])
    }
}

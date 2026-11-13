import BuildDeskCore
@testable import BuildDeskUI
import Foundation

/// A project's release commands, answered from values a test sets.
struct FakeReleases: ReleaseProviding {
    let status = Locked<Result<ReleaseStatus, BuildDeskError>>(.success(Sample.releaseStatus))
    let plan = Locked<Result<ReleasePlan, BuildDeskError>>(.success(Sample.releasePlan))
    let result = Locked<Result<ReleaseResult, BuildDeskError>>(
        .success(ReleaseResult(result: "SampleInternal-4.2.4", done: ["Created tag SampleInternal-4.2.4", "Pushed the tag"]))
    )
    let statusCalls = Locked(0)
    let planned = Locked<[ReleaseAction]>([])
    /// Each run as "action title, confirming <plan commit>".
    let ran = Locked<[String]>([])

    func status(_ provider: ReleaseProvider) async throws -> ReleaseStatus {
        statusCalls.value += 1
        return try status.value.get()
    }

    func plan(_ action: ReleaseAction, _ provider: ReleaseProvider) async throws -> ReleasePlan {
        planned.value += [action]
        return try plan.value.get()
    }

    func run(_ action: ReleaseAction, confirming plan: ReleasePlan, _ provider: ReleaseProvider) async throws -> ReleaseResult {
        ran.value += ["\(action.kind.rawValue) \(plan.title), confirming \(plan.commit ?? "none")"]
        return try result.value.get()
    }

    let storeStatus = Locked<Result<ReleaseStoreStatus, BuildDeskError>>(.success(Sample.storeStatus))
    let storeCalls = Locked(0)

    func store(_ provider: ReleaseProvider) async throws -> ReleaseStoreStatus {
        storeCalls.value += 1
        return try storeStatus.value.get()
    }
}

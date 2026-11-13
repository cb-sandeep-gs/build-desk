@testable import BuildDeskCore
import XCTest

final class ReleaseExtrasTests: XCTestCase {
    private let provider = ReleaseProvider(
        commands: ReleaseCommands(
            status: ["./tool", "status"], plan: ["./tool", "plan"], run: ["./tool", "run"], checks: ["./tool", "checks"],
            artifact: ["./tool", "artifact"]
        ),
        folder: URL(fileURLWithPath: "/projects/shop")
    )
    private let build = ReleaseBuild(id: "ShopInternal-4.2.3", app: "shop", track: "internal", kind: .testflight, version: "4.2.3")

    private func runner(_ output: String) -> FakeToolRunner {
        let runner = FakeToolRunner()
        runner.onRun = { _ in ToolResult(exitCode: 0, stdout: Data(output.utf8)) }
        return runner
    }

    func testTheArtifactCommandGetsTheBuildAndTheFolderAndAnswersWithTheFile() async throws {
        let runner = runner(#"{"contract":1,"file":"/downloads/ShopInternal-4.2.3-ad-hoc.ipa","kind":"ad-hoc","bytes":61000000}"#)

        let artifact = try await ReleaseClient(toolRunner: runner).artifact(of: build, to: URL(fileURLWithPath: "/downloads"), provider)

        XCTAssertEqual(artifact.url.lastPathComponent, "ShopInternal-4.2.3-ad-hoc.ipa")
        XCTAssertEqual(artifact.bytes, 61_000_000)
        XCTAssertEqual(
            runner.commands.first?.arguments, ["artifact", "--app", "shop", "--build", "ShopInternal-4.2.3", "--output", "/downloads"]
        )
    }

    func testChecksAreReadWithAdvisoryGatesKeptApart() async throws {
        let runner = runner("""
        {"contract":1,"go":false,"hint":"Fix: Packages.",
         "gates":[{"title":"Packages","passed":false,"blocking":true,"seconds":21.5},
                  {"title":"Style","passed":false,"blocking":false,"seconds":3}]}
        """)

        let checks = try await ReleaseClient(toolRunner: runner).checks(provider)

        XCTAssertFalse(checks.isGo)
        XCTAssertEqual(checks.gates.map(\.blocking), [true, false])
        XCTAssertEqual(checks.gates.first?.seconds, 21.5)
        XCTAssertEqual(checks.hint, "Fix: Packages.")
    }

    func testAnActionOnABuildCarriesTheBuildAndItsNotes() async throws {
        let runner = runner(#"{"contract":1,"title":"What to Test of build 812","steps":["Set What to Test"],"notes":"Faster search"}"#)
        let action = ReleaseAction(kind: .notes, app: "shop", notes: "Faster search", build: "ShopInternal-4.2.3")

        let plan = try await ReleaseClient(toolRunner: runner).plan(action, provider)

        // No commit: an action on an existing build does not depend on where the code is.
        XCTAssertNil(plan.commit)
        let arguments = try XCTUnwrap(runner.commands.first?.arguments)
        XCTAssertEqual(Array(arguments.prefix(7)), ["plan", "--action", "notes", "--app", "shop", "--build", "ShopInternal-4.2.3"])
        XCTAssertEqual(arguments.dropLast().last, "--notes-file")
        XCTAssertTrue(ReleaseAction.Kind.testers.isBuildAction)
        XCTAssertFalse(ReleaseAction.Kind.store.isBuildAction)
    }

    func testAProjectWithoutTheCommandsSaysSo() async {
        let bare = ReleaseProvider(commands: ReleaseCommands(status: ["./tool"]), folder: URL(fileURLWithPath: "/projects/shop"))
        let client = ReleaseClient(toolRunner: FakeToolRunner())
        do {
            _ = try await client.artifact(of: build, to: URL(fileURLWithPath: "/downloads"), bare)
            XCTFail("expected a missing command")
        } catch {
            XCTAssertEqual((error as? BuildDeskError), .releaseCommandMissing(name: "artifact"))
        }
        do {
            _ = try await client.checks(bare)
            XCTFail("expected a missing command")
        } catch {
            XCTAssertEqual((error as? BuildDeskError), .releaseCommandMissing(name: "checks"))
        }
    }
}

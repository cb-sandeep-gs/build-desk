@testable import BuildDeskCore
import XCTest

final class ReleaseContractTests: XCTestCase {
    private let statusJSON = """
    {"contract":1,
     "head":{"branch":"develop","commit":"a41c9e2","subject":"Fix the cart total","dirty":false},
     "apps":[{"id":"shop","name":"Shop","version":"4.2",
       "tracks":[
         {"id":"internal","name":"Internal testers","notes":"generated","commitsSince":14,
          "latest":{"id":"ShopInternal-4.2.3","app":"shop","track":"internal","kind":"testflight","version":"4.2.3",
                    "commit":"9f0c","date":1794472609,"branch":"develop","notes":"Faster search"}},
         {"id":"partner","name":"Partners","notes":"written","latest":null}],
       "store":{"id":"ShopStore-4.1","app":"shop","track":null,"kind":"store","version":"4.1","from":"ShopInternal-4.1.9"},
       "commitsSinceStore":120}],
     "builds":[{"id":"ShopInternal-4.2.3","app":"shop","track":"internal","kind":"testflight","version":"4.2.3"}],
     "branches":["develop","main"],
     "somethingNewer":true}
    """

    private let provider = ReleaseProvider(
        commands: ReleaseCommands(status: ["./tool", "release", "status"], plan: ["./tool", "release", "plan"], run: ["python3", "run.py"]),
        folder: URL(fileURLWithPath: "/projects/shop")
    )

    private func runner(_ output: String, exit: Int32 = 0) -> FakeToolRunner {
        let runner = FakeToolRunner()
        runner.onRun = { _ in ToolResult(exitCode: exit, stdout: Data(output.utf8), stderr: Data("log line".utf8)) }
        return runner
    }

    func testStatusIsReadAndUnknownFieldsAreIgnored() async throws {
        let runner = runner(statusJSON)
        let status = try await ReleaseClient(toolRunner: runner).status(provider)

        XCTAssertEqual(status.head?.branch, "develop")
        let app = try XCTUnwrap(status.apps.first)
        XCTAssertEqual(app.version, "4.2")
        XCTAssertEqual(app.tracks.map(\.id), ["internal", "partner"])
        XCTAssertEqual(app.tracks[0].latest?.version, "4.2.3")
        XCTAssertEqual(app.tracks[0].notes, .generated)
        XCTAssertEqual(app.tracks[1].notes, .written)
        XCTAssertNil(app.tracks[1].latest)
        XCTAssertEqual(app.store?.kind, .store)
        XCTAssertEqual(app.store?.from, "ShopInternal-4.1.9")
        XCTAssertEqual(status.branches, ["develop", "main"])

        // The project's own tool, by its full path, started in the project's folder.
        let command = try XCTUnwrap(runner.commands.first)
        XCTAssertEqual(command.executable, "/projects/shop/tool")
        XCTAssertEqual(command.arguments, ["release", "status"])
        XCTAssertEqual(command.workingDirectory?.path, "/projects/shop")
    }

    func testAPlanCarriesTheActionAsFlagsAndTheNotesAsAFile() async throws {
        let runner = FakeToolRunner()
        let written = Locked<String?>(nil)
        runner.onRun = { command in
            // The notes file exists while the command runs.
            if let index = command.arguments.firstIndex(of: "--notes-file") {
                written.value = try? String(contentsOfFile: command.arguments[index + 1], encoding: .utf8)
            }
            let plan = #"{"contract":1,"title":"ShopPartner-4.2.1","steps":["Create tag","Push"],"notes":"For partners","commit":"a41"}"#
            return ToolResult(exitCode: 0, stdout: Data(plan.utf8))
        }
        let action = ReleaseAction(kind: .testflight, app: "shop", track: "partner", branch: "main", notes: "For partners\nline two")

        let plan = try await ReleaseClient(toolRunner: runner).plan(action, provider)

        XCTAssertEqual(plan.title, "ShopPartner-4.2.1")
        XCTAssertEqual(plan.steps, ["Create tag", "Push"])
        XCTAssertEqual(written.value, "For partners\nline two")
        let arguments = try XCTUnwrap(runner.commands.first?.arguments)
        XCTAssertEqual(Array(arguments.prefix(10)), [
            "release", "plan", "--action", "testflight", "--app", "shop", "--track", "partner", "--branch", "main",
        ])
        // The file is gone once the command has finished.
        let notesFile = arguments[arguments.count - 1]
        XCTAssertFalse(FileManager.default.fileExists(atPath: notesFile))
    }

    func testRunSendsThePlansCommitSoAStalePlanCanBeRefused() async throws {
        let runner = runner(#"{"contract":1,"result":"ShopStore-4.2","done":["Created tag ShopStore-4.2","Pushed the tag"]}"#)
        let action = ReleaseAction(kind: .store, app: "shop", from: "ShopInternal-4.2.3")
        let plan = ReleasePlan(title: "ShopStore-4.2", steps: [], commit: "9f0c")

        let result = try await ReleaseClient(toolRunner: runner).run(action, confirming: plan, provider)

        XCTAssertEqual(result.done.count, 2)
        // A bare tool name is found through the PATH.
        let command = try XCTUnwrap(runner.commands.first)
        XCTAssertEqual(command.executable, "/usr/bin/env")
        XCTAssertEqual(command.arguments, [
            "python3", "run.py", "--action", "store", "--app", "shop", "--from", "ShopInternal-4.2.3", "--expect", "9f0c",
        ])
    }

    func testAProvidersOwnWordsAreShownWhenItFails() async {
        func failure(_ output: String, exit: Int32, _ work: (ReleaseClient) async throws -> Void) async -> BuildDeskError? {
            do {
                try await work(ReleaseClient(toolRunner: runner(output, exit: exit)))
                return nil
            } catch {
                return error as? BuildDeskError
            }
        }
        let provider = provider
        let refusal = #"{"error":"The checkout has changes. Commit or stash them first."}"#
        let told = await failure(refusal, exit: 1) { _ = try await $0.status(provider) }
        XCTAssertEqual(told, .releaseFailed(message: "The checkout has changes. Commit or stash them first."))

        // Not JSON at all: the tail of what the tool printed.
        let crashed = await failure("Traceback", exit: 2) { _ = try await $0.status(provider) }
        XCTAssertEqual(crashed, .releaseFailed(message: "log line"))

        let garbled = await failure("{}", exit: 0) { _ = try await $0.status(provider) }
        guard case .unexpectedOutput = garbled else { return XCTFail("wrong error: \(String(describing: garbled))") }

        let newer = await failure(#"{"contract":2,"apps":[],"builds":[]}"#, exit: 0) { _ = try await $0.status(provider) }
        XCTAssertEqual(newer, .releaseFailed(message: "The project speaks release contract 2; this Build Desk reads 1. Update Build Desk."))
    }

    func testAProjectWithoutPlanOrRunIsReadOnly() async {
        let readOnly = ReleaseProvider(commands: ReleaseCommands(status: ["./tool"]), folder: URL(fileURLWithPath: "/projects/shop"))
        let client = ReleaseClient(toolRunner: FakeToolRunner())
        do {
            _ = try await client.plan(ReleaseAction(kind: .testflight, app: "shop"), readOnly)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? BuildDeskError, .releaseCommandMissing(name: "plan"))
        }
    }

    func testTheSettingsFileNamesTheCommandsAndTheSnapshotKnowsTheirFolder() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.write("", to: ".git/HEAD")
        try folder.write(Fixtures.projectFile, to: "App/Sample.xcodeproj/project.pbxproj")
        try folder.write(
            #"{"release": {"status": ["./tool", "status"], "plan": ["./tool", "plan"], "run": ["./tool", "run"]}}"#,
            to: ".builddesk.json"
        )
        let container = try ProjectContainer(url: folder.url.appendingPathComponent("App/Sample.xcodeproj"))

        let snapshot = try ProjectReader(toolRunner: FakeToolRunner()).quickSnapshot(of: container)

        XCTAssertNil(snapshot.configProblem)
        let provider = try XCTUnwrap(snapshot.releaseProvider)
        XCTAssertEqual(provider.commands.status, ["./tool", "status"])
        XCTAssertEqual(provider.commands.run, ["./tool", "run"])
        XCTAssertNil(provider.commands.store)
        // Commands run from where the settings file is, not from where the project is.
        XCTAssertEqual(provider.folder.standardizedFileURL.path, folder.url.standardizedFileURL.path)

        // No release section: no Release mode.
        try folder.write(#"{"defaultScheme": "Sample"}"#, to: ".builddesk.json")
        XCTAssertNil(try ProjectReader(toolRunner: FakeToolRunner()).quickSnapshot(of: container).releaseProvider)
    }

    func testAToolIsStartedInItsWorkingFolder() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let command = ToolCommand(executable: "/bin/pwd", arguments: [], workingDirectory: folder.url)

        let result = try await ProcessToolRunner().run(command)

        let printed = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(URL(fileURLWithPath: printed).resolvingSymlinksInPath().path, folder.url.resolvingSymlinksInPath().path)
    }
}

/// A value a test sets and a closure on another thread reads.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

final class ReleaseStoreContractTests: XCTestCase {
    private let provider = ReleaseProvider(
        commands: ReleaseCommands(status: ["./tool", "status"], store: ["./tool", "store"]), folder: URL(fileURLWithPath: "/projects/shop")
    )

    func testStoreStateIsRead() async throws {
        let runner = FakeToolRunner()
        let json = """
        {"contract":1,"connected":true,"hint":null,"apps":[{"id":"shop",
          "builds":[{"id":"ShopInternal-4.2.3","number":"812","cloud":"running","cloudDetail":"Release workflow","testing":null},
                    {"id":"ShopInternal-4.2.2","cloud":"succeeded","testing":"In testing","groups":["Staff"]}],
          "storeVersions":[{"version":"4.2","state":"Prepare for submission"}],
          "alerts":[{"severity":"warning","message":"runs: not visible to this key"}]}]}
        """
        runner.onRun = { _ in ToolResult(exitCode: 0, stdout: Data(json.utf8)) }

        let store = try await ReleaseClient(toolRunner: runner).store(provider)

        XCTAssertTrue(store.connected)
        XCTAssertEqual(store.apps.first?.builds.map(\.cloudState), [.running, .succeeded])
        XCTAssertEqual(store.apps.first?.builds.last?.groups, ["Staff"])
        XCTAssertEqual(store.apps.first?.alerts?.first?.isError, false)
        XCTAssertEqual(runner.commands.first?.arguments, ["store"])
    }

    func testNotConnectedIsAnAnswerAndAMissingCommandIsNot() async throws {
        let runner = FakeToolRunner()
        let notConnected = #"{"contract":1,"connected":false,"hint":"Log in first.","apps":[]}"#
        runner.onRun = { _ in ToolResult(exitCode: 0, stdout: Data(notConnected.utf8)) }
        let store = try await ReleaseClient(toolRunner: runner).store(provider)
        XCTAssertEqual(store, ReleaseStoreStatus(connected: false, hint: "Log in first."))

        let noStore = ReleaseProvider(commands: ReleaseCommands(status: ["./tool"]), folder: provider.folder)
        do {
            _ = try await ReleaseClient(toolRunner: runner).store(noStore)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? BuildDeskError, .releaseCommandMissing(name: "store"))
        }
    }
}

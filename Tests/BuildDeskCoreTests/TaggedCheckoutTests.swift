@testable import BuildDeskCore
import XCTest

/// Runs real git in a temporary folder: the point of the copy is what git does with it.
final class TaggedCheckoutTests: XCTestCase {
    private var scratch = URL(fileURLWithPath: "/")
    private var repository: URL { scratch.appendingPathComponent("Sample") }
    private var copies: URL { scratch.appendingPathComponent("copies") }
    private let runner = ProcessToolRunner()

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("builddesk-tagged-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let project = repository.appendingPathComponent("App/Sample.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try await git(["init", "--quiet"])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    @discardableResult
    private func git(_ arguments: [String]) async throws -> String {
        // A fixed author, so the test does not depend on the machine's git settings.
        let identity = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"]
        let command = ToolCommand(executable: BuildDeskConstants.ToolPath.git, arguments: ["-C", repository.path] + identity + arguments)
        let result = try await runner.run(command)
        XCTAssertTrue(result.succeeded, String(decoding: result.stderr, as: UTF8.self))
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Writes the file, commits it and returns the commit's full hash.
    private func commit(_ text: String) async throws -> String {
        try text.write(to: repository.appendingPathComponent("App/version.txt"), atomically: true, encoding: .utf8)
        let projectFile = repository.appendingPathComponent("App/Sample.xcodeproj/project.pbxproj")
        try "project".write(to: projectFile, atomically: true, encoding: .utf8)
        try await git(["add", "-A"])
        try await git(["commit", "--quiet", "-m", text])
        return try await git(["rev-parse", "HEAD"])
    }

    private func container() throws -> ProjectContainer {
        try ProjectContainer(url: repository.appendingPathComponent("App/Sample.xcodeproj"))
    }

    private func version(in source: TaggedSource) throws -> String {
        try String(contentsOf: source.container.url.deletingLastPathComponent().appendingPathComponent("version.txt"), encoding: .utf8)
    }

    func testTheCopyIsAtTheAskedCommitAndTheCheckoutIsNotTouched() async throws {
        let first = try await commit("1.0")
        let second = try await commit("2.0")
        // Work in progress in the person's checkout.
        try "3.0-wip".write(to: repository.appendingPathComponent("App/version.txt"), atomically: true, encoding: .utf8)
        let checkout = TaggedCheckout(root: copies)

        let source = try await checkout.prepare(commit: String(first.prefix(10)), of: try container())

        XCTAssertEqual(source.commit, first)
        XCTAssertEqual(try version(in: source), "1.0")
        XCTAssertEqual(source.container.url.lastPathComponent, "Sample.xcodeproj")
        XCTAssertTrue(source.folder.path.hasPrefix(copies.path))
        // The checkout: same commit, same branch, same unsaved work, and no extra worktree.
        let head = try await git(["rev-parse", "HEAD"])
        XCTAssertEqual(head, second)
        XCTAssertEqual(try String(contentsOf: repository.appendingPathComponent("App/version.txt"), encoding: .utf8), "3.0-wip")
        let worktrees = try await git(["worktree", "list"])
        XCTAssertEqual(worktrees.split(separator: "\n").count, 1)
    }

    func testOneCopyIsMovedFromCommitToCommit() async throws {
        let first = try await commit("1.0")
        let second = try await commit("2.0")
        let checkout = TaggedCheckout(root: copies)

        let one = try await checkout.prepare(commit: first, of: try container())
        // Something a build left behind in the copy survives the move.
        let leftover = one.folder.appendingPathComponent("build-output.txt")
        try "kept".write(to: leftover, atomically: true, encoding: .utf8)
        let two = try await checkout.prepare(commit: second, of: try container())

        XCTAssertEqual(one.folder, two.folder)
        XCTAssertEqual(try version(in: two), "2.0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: copies.path).count, 1)

        let existing = await checkout.existing(for: try container())
        XCTAssertEqual(existing?.commit, second)
        XCTAssertEqual(existing?.container, two.container)
        XCTAssertGreaterThan(existing?.bytes ?? 0, 0)
    }

    func testRemoveDeletesOnlyACopyOfItsOwn() async throws {
        let first = try await commit("1.0")
        let checkout = TaggedCheckout(root: copies)
        let none = await checkout.existing(for: try container())
        XCTAssertNil(none)

        let source = try await checkout.prepare(commit: first, of: try container())
        try await checkout.remove(source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.folder.path))

        // A folder that is not one of its copies is refused.
        let foreign = TaggedSource(container: try container(), folder: repository, commit: first)
        do {
            try await checkout.remove(foreign)
            XCTFail("Removing a folder outside the copies must fail")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.path))
    }

    func testACommitThisMacDoesNotHaveSaysToFetch() async throws {
        _ = try await commit("1.0")
        do {
            _ = try await TaggedCheckout(root: copies).prepare(commit: "0123456789abcdef0123456789abcdef01234567", of: try container())
            XCTFail("An unknown commit must fail")
        } catch let error as BuildDeskError {
            XCTAssertEqual(error.errorDescription, "This Mac doesn't have commit 0123456 yet. Fetch the project's tags, then try again.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: copies.path))
    }

    func testAProjectOutsideGitHasNoTaggedCode() async throws {
        let loose = scratch.appendingPathComponent("Loose/Loose.xcodeproj")
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        do {
            _ = try await TaggedCheckout(root: copies).prepare(commit: "abc", of: try ProjectContainer(url: loose))
            XCTFail("A folder outside git must fail")
        } catch let error as BuildDeskError {
            XCTAssertEqual(error.errorDescription, "Loose is not in a git checkout, so there is no tagged code to build.")
        }
    }

    func testTheSamePathAlwaysGetsTheSameFolder() {
        XCTAssertEqual(TaggedCheckout.shortHash(of: "/projects/Sample"), TaggedCheckout.shortHash(of: "/projects/Sample"))
        XCTAssertNotEqual(TaggedCheckout.shortHash(of: "/projects/Sample"), TaggedCheckout.shortHash(of: "/other/Sample"))
        XCTAssertEqual(TaggedCheckout.shortHash(of: "/projects/Sample").count, BuildDeskConstants.TaggedSources.hashLength)
    }
}

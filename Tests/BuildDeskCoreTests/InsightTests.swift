@testable import BuildDeskCore
import XCTest

final class RunHistoryTests: XCTestCase {
    private func record(_ scheme: String, project: String = "/projects/Sample.xcodeproj", daysAgo: Double) -> RunRecord {
        RunRecord(
            date: Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * 86_400), projectPath: project, scheme: scheme,
            configuration: "Debug", deviceName: "Test iPhone", deviceKind: .physical, action: .buildAndInstall, result: .succeeded,
            totalSeconds: 60, buildSeconds: 50, taskCount: 100, warningCount: 3, newWarningCount: 1, errorCount: 0,
            source: SourceState(branch: "main", commit: "1a2b3c4", hasLocalChanges: false)
        )
    }

    func testRecordsSurviveANewStoreAndComeNewestFirstPerProject() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let store = FileRunHistoryStore(directory: folder.url.appendingPathComponent("support"))
        await store.append(record("Sample", daysAgo: 2))
        await store.append(record("Other", project: "/projects/Other.xcodeproj", daysAgo: 1))
        await store.append(record("SampleKit", daysAgo: 0))

        // A new store reads what the first one wrote, as after the app is reopened.
        let reopened = FileRunHistoryStore(directory: folder.url.appendingPathComponent("support"))
        let records = await reopened.records(forProject: "/projects/Sample.xcodeproj")

        XCTAssertEqual(records.map(\.scheme), ["SampleKit", "Sample"])
        XCTAssertEqual(records.first, record("SampleKit", daysAgo: 0).withID(records[0].id))
    }

    func testOnlyTheNewestRecordsAreKept() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let store = FileRunHistoryStore(directory: folder.url)
        let extra = 3
        for index in 0..<(FileRunHistoryStore.recordLimit + extra) {
            await store.append(record("Run \(index)", daysAgo: Double(FileRunHistoryStore.recordLimit + extra - index)))
        }
        let records = await store.records(forProject: "/projects/Sample.xcodeproj")

        XCTAssertEqual(records.count, FileRunHistoryStore.recordLimit)
        XCTAssertEqual(records.last?.scheme, "Run \(extra)")
    }

    func testADamagedFileIsAnEmptyHistory() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.write("not json", to: "history.json")
        try folder.write("{", to: "known-warnings.json")
        let store = FileRunHistoryStore(directory: folder.url)

        let records = await store.records(forProject: "/projects/Sample.xcodeproj")
        let known = await store.knownWarnings(for: "key")
        XCTAssertTrue(records.isEmpty)
        XCTAssertNil(known)
    }

    func testKnownWarningsOnlyGrowAndSurviveANewStore() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let store = FileRunHistoryStore(directory: folder.url)
        let before = await store.knownWarnings(for: "key")
        XCTAssertNil(before)

        await store.addKnownWarnings(["a", "b"], for: "key")
        // An incremental build printed only one of them, plus a new one.
        await store.addKnownWarnings(["b", "c"], for: "key")

        let known = await FileRunHistoryStore(directory: folder.url).knownWarnings(for: "key")
        XCTAssertEqual(known, ["a", "b", "c"])
        let other = await store.knownWarnings(for: "other key")
        XCTAssertNil(other)
    }

    func testNewWarningsIgnoreLineNumbersAndRepeats() {
        let moved = Diagnostic(severity: .warning, message: "deprecated", file: "/src/Home.swift", line: 90, column: 2)
        let fresh = Diagnostic(severity: .warning, message: "unused variable", file: "/src/Home.swift", line: 12, column: 9)
        let sameElsewhere = Diagnostic(severity: .warning, message: "deprecated", file: "/src/Cart.swift", line: 4, column: 1)
        // The known warning was on line 41 when it was first seen.
        let earlier = Diagnostic(severity: .warning, message: "deprecated", file: "/src/Home.swift", line: 41, column: 13)
        let known: Set<String> = [earlier.fingerprint]

        let new = WarningDiff.newWarnings(in: [moved, fresh, sameElsewhere, fresh], known: known)

        XCTAssertEqual(new, [fresh, sameElsewhere])
        XCTAssertEqual(WarningDiff.key(projectPath: "/p/A.xcodeproj", scheme: "A", configuration: "Debug"), "/p/A.xcodeproj|A|Debug")
    }
}

private extension RunRecord {
    /// The same record under another identifier, for comparing everything else.
    func withID(_ id: UUID) -> RunRecord {
        RunRecord(
            id: id, date: date, projectPath: projectPath, scheme: scheme, configuration: configuration, deviceName: deviceName,
            deviceKind: deviceKind, action: action, result: result, totalSeconds: totalSeconds, buildSeconds: buildSeconds,
            taskCount: taskCount, warningCount: warningCount, newWarningCount: newWarningCount, errorCount: errorCount, source: source
        )
    }
}

final class BuildFolderTests: XCTestCase {
    private func infoPlist(_ path: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>WorkspacePath</key><string>\(path)</string></dict></plist>
        """
    }

    /// A DerivedData folder with two projects of the same name in different places.
    private func makeDerivedData() throws -> (TemporaryFolder, ProjectContainer) {
        let folder = try TemporaryFolder()
        let container = try ProjectContainer(url: URL(fileURLWithPath: "/projects/app/Sample.xcodeproj"))
        try folder.write(infoPlist("/projects/other/Sample.xcodeproj"), to: "Sample-aaaa/info.plist")
        try folder.write(infoPlist("/projects/app/Sample.xcodeproj"), to: "Sample-bbbb/info.plist")
        try folder.write("product", to: "Sample-bbbb/Build/Products/Debug-iphoneos/Sample.app/Sample")
        try folder.write("package", to: "Sample-bbbb/SourcePackages/checkouts/Kit/Package.swift")
        try folder.write("cache", to: "ModuleCache.noindex/module")
        return (folder, container)
    }

    private func service(_ folder: TemporaryFolder, kilobytes: String = "4521984") -> (BuildFolderService, FakeToolRunner) {
        let runner = FakeToolRunner()
        runner.onRun = { command in ToolResult(exitCode: 0, stdout: Data("\(kilobytes)\t\(command.arguments.last ?? "")\n".utf8)) }
        return (BuildFolderService(toolRunner: runner, derivedDataRoot: folder.url), runner)
    }

    func testTheFolderIsFoundByTheProjectPathItRecords() async throws {
        let (folder, container) = try makeDerivedData()
        defer { folder.remove() }
        let (service, runner) = service(folder)

        let found = await service.buildFolder(for: container)

        XCTAssertEqual(found?.url.lastPathComponent, "Sample-bbbb")
        XCTAssertEqual(found?.buildBytes, 4_521_984 * 1024)
        XCTAssertEqual(runner.commands.first?.text.hasPrefix("du -sk "), true)
        XCTAssertEqual(runner.commands.first?.arguments.last?.hasSuffix("Sample-bbbb/Build"), true)
    }

    func testAProjectNeverBuiltHereHasNoFolder() async throws {
        let (folder, _) = try makeDerivedData()
        defer { folder.remove() }
        let (service, runner) = service(folder)
        let unknown = try ProjectContainer(url: URL(fileURLWithPath: "/projects/new/Fresh.xcodeproj"))

        let found = await service.buildFolder(for: unknown)

        XCTAssertNil(found)
        XCTAssertTrue(runner.commands.isEmpty)
    }

    func testCleanRemovesOnlyTheBuildOutput() async throws {
        let (folder, container) = try makeDerivedData()
        defer { folder.remove() }
        let (service, _) = service(folder)
        let found = try await XCTUnwrapAsync(await service.buildFolder(for: container))

        try await service.clean(found)

        let files = FileManager.default
        XCTAssertFalse(files.fileExists(atPath: found.buildURL.path))
        // Downloaded packages, the other project and the shared module cache are untouched.
        XCTAssertTrue(files.fileExists(atPath: found.url.appendingPathComponent("SourcePackages/checkouts/Kit/Package.swift").path))
        XCTAssertTrue(files.fileExists(atPath: folder.url.appendingPathComponent("Sample-aaaa/info.plist").path))
        XCTAssertTrue(files.fileExists(atPath: folder.url.appendingPathComponent("ModuleCache.noindex/module").path))

        let after = await service.buildFolder(for: container)
        XCTAssertNil(after?.buildBytes)
        // Cleaning again is not an error.
        try await service.clean(found)
    }

    func testRemoveAllDeletesTheWholeFolderOfOneProjectOnly() async throws {
        let (folder, container) = try makeDerivedData()
        defer { folder.remove() }
        let (service, runner) = service(folder)
        let found = try await XCTUnwrapAsync(await service.buildFolder(for: container))

        // The whole folder is measured, packages included.
        let total = await service.totalBytes(of: found)
        XCTAssertEqual(total, 4_521_984 * 1024)
        XCTAssertEqual(runner.commands.last?.arguments.last?.hasSuffix("Sample-bbbb"), true)

        try await service.removeAll(found)

        let files = FileManager.default
        XCTAssertFalse(files.fileExists(atPath: found.url.path))
        XCTAssertTrue(files.fileExists(atPath: folder.url.appendingPathComponent("Sample-aaaa/info.plist").path))
        XCTAssertTrue(files.fileExists(atPath: folder.url.appendingPathComponent("ModuleCache.noindex/module").path))

        // A folder that is not one of the build root's own is refused.
        let outside = BuildFolder(url: folder.url, buildBytes: nil)
        do {
            try await service.removeAll(outside)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(files.fileExists(atPath: folder.url.path))
        }
    }

    func testCleanRefusesAFolderOutsideDerivedData() async throws {
        let (folder, _) = try makeDerivedData()
        defer { folder.remove() }
        let (service, _) = service(folder)
        let elsewhere = try TemporaryFolder()
        defer { elsewhere.remove() }
        try elsewhere.write("keep", to: "Project/Build/file")
        let outside = BuildFolder(url: elsewhere.url.appendingPathComponent("Project"), buildBytes: 1)

        do {
            try await service.clean(outside)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: outside.buildURL.appendingPathComponent("file").path))
        }
    }
}

/// `XCTUnwrap` for a value that had to be awaited.
func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

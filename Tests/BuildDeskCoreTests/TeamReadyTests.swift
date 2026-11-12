@testable import BuildDeskCore
import XCTest

final class ProjectConfigTests: XCTestCase {
    /// A repository with a project two folders down.
    private func makeRepository(config: String?, at configPath: String = ".builddesk.json") throws -> (TemporaryFolder, ProjectContainer) {
        let folder = try TemporaryFolder()
        try folder.write("", to: ".git/HEAD")
        try folder.write(Fixtures.projectFile, to: "Apps/iOS/Sample.xcodeproj/project.pbxproj")
        try folder.write(Fixtures.scheme(build: ["Sample.app"], runnable: "Sample.app"),
                         to: "Apps/iOS/Sample.xcodeproj/xcshareddata/xcschemes/Sample.xcscheme")
        if let config { try folder.write(config, to: configPath) }
        return (folder, try ProjectContainer(url: folder.url.appendingPathComponent("Apps/iOS/Sample.xcodeproj")))
    }

    func testConfigIsFoundAtTheRepositoryRootAndCarriedByTheSnapshot() throws {
        let json = """
        {"favoriteSchemes": ["Sample"], "hiddenSchemes": ["*Tests", "Legacy"], "defaultScheme": "Sample",
         "defaultConfiguration": "Staging Debug"}
        """
        let (folder, container) = try makeRepository(config: json)
        defer { folder.remove() }

        let snapshot = try ProjectReader(toolRunner: FakeToolRunner()).quickSnapshot(of: container)

        XCTAssertEqual(snapshot.config, ProjectConfig(
            favoriteSchemes: ["Sample"], hiddenSchemes: ["*Tests", "Legacy"], defaultScheme: "Sample",
            defaultConfiguration: "Staging Debug"
        ))
        XCTAssertNil(snapshot.configProblem)
    }

    func testAFileBesideTheProjectWinsAndNoFileMeansDefaults() throws {
        let (folder, container) = try makeRepository(config: #"{"defaultScheme": "Near"}"#, at: "Apps/iOS/.builddesk.json")
        defer { folder.remove() }
        try folder.write(#"{"defaultScheme": "Far"}"#, to: ".builddesk.json")
        XCTAssertEqual(ProjectConfigLoader.load(for: container).config.defaultScheme, "Near")

        let (bare, bareContainer) = try makeRepository(config: nil)
        defer { bare.remove() }
        let nothing = ProjectConfigLoader.load(for: bareContainer)
        XCTAssertEqual(nothing.config, ProjectConfig())
        XCTAssertNil(nothing.fileURL)
        XCTAssertNil(nothing.problem)
    }

    func testTheSearchStopsAtTheRepositoryRoot() throws {
        let outer = try TemporaryFolder()
        defer { outer.remove() }
        // A file above the repository belongs to something else.
        try outer.write(#"{"defaultScheme": "Outside"}"#, to: ".builddesk.json")
        try outer.write("", to: "repo/.git/HEAD")
        try outer.write(Fixtures.projectFile, to: "repo/Sample.xcodeproj/project.pbxproj")
        let container = try ProjectContainer(url: outer.url.appendingPathComponent("repo/Sample.xcodeproj"))

        XCTAssertNil(ProjectConfigLoader.fileURL(for: container))
    }

    func testABrokenFileIsReportedAndNeverStopsTheProjectFromOpening() throws {
        let cases: [(json: String, problem: String)] = [
            ("{not json", ".builddesk.json can't be used: it is not valid JSON."),
            (#"{"hiddenSchemes": "Tests"}"#, ".builddesk.json can't be used: hiddenSchemes has the wrong kind of value."),
            (#"{"favouriteSchemes": ["Sample"]}"#,
             ".builddesk.json has keys Build Desk doesn't know: favouriteSchemes. "
                + "Known keys: defaultConfiguration, defaultScheme, favoriteSchemes, hiddenSchemes, release."),
        ]
        for (json, problem) in cases {
            let (folder, container) = try makeRepository(config: json)
            defer { folder.remove() }
            let snapshot = try ProjectReader(toolRunner: FakeToolRunner()).quickSnapshot(of: container)
            XCTAssertEqual(snapshot.configProblem, problem)
            XCTAssertEqual(snapshot.schemes.map(\.name), ["Sample"])
        }
    }

    func testHiddenSchemePatterns() {
        let config = ProjectConfig(hiddenSchemes: ["*Tests", "Pods-*", "Legacy", "A*B*C"])
        XCTAssertTrue(config.hides("SampleTests"))
        XCTAssertTrue(config.hides("Pods-Sample"))
        XCTAssertTrue(config.hides("Legacy"))
        XCTAssertTrue(config.hides("A-1-B-2-C"))
        // A pattern matches the whole name, not a part of it.
        XCTAssertFalse(config.hides("LegacyApp"))
        XCTAssertFalse(config.hides("TestsSample"))
        XCTAssertFalse(config.hides("AC"))
        XCTAssertFalse(config.hides("Sample"))
    }
}

final class ClosedGapTests: XCTestCase {
    func testASchemeNamedAfterItsTestsIsATestScheme() throws {
        // It builds the app its tests run in and even has a Run action, like an app scheme.
        let xml = Fixtures.scheme(build: ["Sample.app"], tests: ["SampleTests.xctest"], runnable: "Sample.app")
        XCTAssertEqual(try SchemeFileParser.parse(Data(xml.utf8), name: "SampleTests", isShared: true).kind, .tests)
        XCTAssertEqual(try SchemeFileParser.parse(Data(xml.utf8), name: "Sample", isShared: true).kind, .app)
    }

    func testProjectsInsideWorkspaceGroupsAreFound() throws {
        let workspace = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace version = "1.0">
           <Group location = "group:Apps" name = "Apps">
              <FileRef location = "group:iOS/Sample.xcodeproj"></FileRef>
              <Group location = "group:Shared" name = "Shared">
                 <FileRef location = "group:Kit.xcodeproj"></FileRef>
                 <FileRef location = "container:Tools/Helper.xcodeproj"></FileRef>
              </Group>
           </Group>
           <Group location = "container:" name = "Loose">
              <FileRef location = "group:Top.xcodeproj"></FileRef>
           </Group>
        </Workspace>
        """
        let urls = try WorkspaceFileParser.projectURLs(
            in: Data(workspace.utf8), workspaceURL: URL(fileURLWithPath: "/projects/All.xcworkspace")
        )
        XCTAssertEqual(urls.map(\.path), [
            "/projects/Apps/iOS/Sample.xcodeproj",
            "/projects/Apps/Shared/Kit.xcodeproj",
            "/projects/Tools/Helper.xcodeproj",
            "/projects/Top.xcodeproj",
        ])
    }
}

final class DeviceDoctorTests: XCTestCase {
    private func device(_ json: String) throws -> Device {
        try XCTUnwrap(DeviceCtlParser.parse(Data(#"{"result":{"devices":[\#(json)]}}"#.utf8)).first)
    }

    private let hardware = #""hardwareProperties":{"marketingName":"iPhone 17","platform":"iOS","reality":"physical","udid":"U1"}"#

    func testEachProblemIsNamedMostBasicFirst() throws {
        let ready = try device("""
        {"connectionProperties":{"pairingState":"paired","transportType":"wired","tunnelState":"disconnected"},
         "deviceProperties":{"name":"A","developerModeStatus":"enabled"}, \(hardware)}
        """)
        XCTAssertNil(ready.issue)
        XCTAssertTrue(ready.isReady)

        let untrusted = try device("""
        {"connectionProperties":{"pairingState":"unpaired","transportType":"wired","tunnelState":"disconnected"},
         "deviceProperties":{"name":"A","developerModeStatus":"disabled"}, \(hardware)}
        """)
        XCTAssertEqual(untrusted.issue, .notPaired)
        XCTAssertFalse(untrusted.isReady)

        let noDeveloperMode = try device("""
        {"connectionProperties":{"pairingState":"paired","transportType":"wired","tunnelState":"disconnected"},
         "deviceProperties":{"name":"A","developerModeStatus":"disabled"}, \(hardware)}
        """)
        XCTAssertEqual(noDeveloperMode.issue, .developerModeOff)

        let away = try device("""
        {"connectionProperties":{"pairingState":"paired","tunnelState":"unavailable"},
         "deviceProperties":{"name":"A","developerModeStatus":"disabled"}, \(hardware)}
        """)
        XCTAssertEqual(away.issue, .notConnected)
    }

    func testDeveloperModeIsReadFromTheNewerDictionaryToo() throws {
        let turnedOff = try device("""
        {"properties":{"connection":{"state":"connected","transportType":"wired","pairingState":"paired"},
          "hardware":{"platform":"iOS","reality":"physical","udid":"U2"},
          "state":{"name":"B","developerModeStatus":{"disabled":{}}}}}
        """)
        XCTAssertEqual(turnedOff.issue, .developerModeOff)

        let turnedOn = try device("""
        {"properties":{"connection":{"state":"connected","transportType":"wired","pairingState":"paired"},
          "hardware":{"platform":"iOS","reality":"physical","udid":"U2"},
          "state":{"name":"B","developerModeStatus":{"enabled":{"mode":1}}}}}
        """)
        XCTAssertNil(turnedOn.issue)
    }

    func testEveryIssueSaysWhatToDo() {
        for issue in DeviceIssue.allCases {
            XCTAssertFalse(issue.title.isEmpty)
            XCTAssertTrue(issue.fix(for: "Test iPhone").contains("Test iPhone"))
        }
        XCTAssertEqual(
            DeviceIssue.notPaired.fix(for: "Test iPhone"),
            "Test iPhone doesn't trust this Mac yet. Unlock it, reconnect the cable and tap Trust."
        )
    }

    func testLockStateIsAskedOnlyOfReachableRealDevices() async throws {
        let runner = FakeToolRunner()
        runner.onRun = { command in
            let path = try XCTUnwrap(command.arguments.last)
            let json = #"{"result":{"deviceIdentifier":"X","passcodeRequired":true,"unlockedSinceBoot":true}}"#
            try Data(json.utf8).write(to: URL(fileURLWithPath: path))
            return ToolResult(exitCode: 0)
        }
        let discovery = DeviceDiscovery(toolRunner: runner)

        let locked = await discovery.isLocked(Sample.phone)
        let simulator = await discovery.isLocked(Sample.simulator)
        XCTAssertEqual(locked, true)
        XCTAssertNil(simulator)
        XCTAssertEqual(runner.commands.count, 1)
        XCTAssertEqual(runner.commands[0].arguments.prefix(6), ["devicectl", "device", "info", "lockState", "--device", Sample.phoneID])

        // A tool that fails, or output that does not say, is "not known", never "locked".
        runner.onRun = { _ in ToolResult(exitCode: 1) }
        let unknown = await discovery.isLocked(Sample.phone)
        XCTAssertNil(unknown)
        XCTAssertNil(LockStateParser.isLocked(Data("{}".utf8)))
        XCTAssertEqual(LockStateParser.isLocked(Data(#"{"result":{"passcodeRequired":false}}"#.utf8)), false)
    }
}

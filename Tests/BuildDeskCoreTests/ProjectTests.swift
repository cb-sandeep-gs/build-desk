@testable import BuildDeskCore
import XCTest

final class ProjectParserTests: XCTestCase {
    func testAppSchemeListsBuildTestAndRunTargets() throws {
        let xml = Fixtures.scheme(build: ["Sample.app"], tests: ["SampleTests.xctest"], runnable: "Sample.app")
        let scheme = try SchemeFileParser.parse(Data(xml.utf8), name: "Sample", isShared: true)

        XCTAssertEqual(scheme.kind, .app)
        XCTAssertTrue(scheme.isInstallable)
        XCTAssertEqual(scheme.buildTargets, [SchemeTarget(name: "Sample", productName: "Sample.app")])
        XCTAssertEqual(scheme.testTargets.map(\.name), ["SampleTests"])
        // The Profile action repeats the runnable; only the Run action's counts.
        XCTAssertEqual(scheme.runnable?.productName, "Sample.app")
    }

    func testSchemeKindFollowsItsFirstBuildTarget() throws {
        func kind(build: [String], tests: [String] = []) throws -> SchemeKind {
            try SchemeFileParser.parse(Data(Fixtures.scheme(build: build, tests: tests).utf8), name: "S", isShared: true).kind
        }
        // An extension scheme also builds its host app, but lists the extension first.
        XCTAssertEqual(try kind(build: ["SampleWidget.appex", "Sample.app"]), .appExtension)
        XCTAssertEqual(try kind(build: ["SampleKit.framework"]), .framework)
        XCTAssertEqual(try kind(build: ["libSample.a"]), .framework)
        XCTAssertEqual(try kind(build: [], tests: ["SampleTests.xctest"]), .tests)
        XCTAssertEqual(try kind(build: ["SampleTests.xctest"]), .tests)
        // A test scheme that builds its host app, with no Run action, is still a test scheme.
        XCTAssertEqual(try kind(build: ["Sample.app"], tests: ["SampleTests.xctest"]), .tests)
        XCTAssertEqual(try kind(build: ["Sample.app"]), .app)
        XCTAssertEqual(try kind(build: []), .other)
    }

    func testReferenceWithoutATargetNameUsesTheProductName() throws {
        // Seen in real projects: the Run action's reference carries no BlueprintName.
        let xml = Fixtures.scheme(build: ["Sample.app"], tests: ["SampleTests.xctest"], runnable: "Sample.app")
            .replacingOccurrences(of: " BlueprintName = \"Sample\"", with: "")
        let scheme = try SchemeFileParser.parse(Data(xml.utf8), name: "Sample", isShared: true)

        XCTAssertEqual(scheme.runnable, SchemeTarget(name: "Sample", productName: "Sample.app"))
        XCTAssertEqual(scheme.kind, .app)
    }

    func testBrokenSchemeFileThrows() {
        XCTAssertThrowsError(try SchemeFileParser.parse(Data("<Scheme><BuildAction>".utf8), name: "S", isShared: true))
    }

    func testProjectFileGivesTargetsAndConfigurations() throws {
        let file = try ProjectFileParser.parse(Data(Fixtures.projectFile.utf8))

        XCTAssertEqual(file.targets, [
            ProjectTarget(name: "Sample", kind: .application),
            ProjectTarget(name: "SampleWidget", kind: .appExtension),
            ProjectTarget(name: "SampleTests", kind: .unitTests),
            // An aggregate target has no product type.
            ProjectTarget(name: "Docs", kind: .other),
            ProjectTarget(name: "SampleKit", kind: .framework),
        ])
        XCTAssertEqual(file.configurations, ["Debug", "Staging Debug", "Release"])
        XCTAssertEqual(file.defaultConfiguration, "Release")
    }

    func testProjectFileWithoutRootObjectThrows() {
        XCTAssertThrowsError(try ProjectFileParser.parse(Data("{ objects = {}; }".utf8)))
    }

    func testProductKindFromProductType() {
        XCTAssertEqual(ProductKind(productType: "com.apple.product-type.application.watchapp2"), .watchApplication)
        XCTAssertEqual(ProductKind(productType: "com.apple.product-type.extensionkit-extension"), .appExtension)
        XCTAssertEqual(ProductKind(productType: "com.apple.product-type.library.static"), .library)
        XCTAssertEqual(ProductKind(productType: "com.apple.product-type.bundle.ui-testing"), .uiTests)
        XCTAssertEqual(ProductKind(productType: "com.apple.product-type.tool"), .other)
    }

    func testWorkspaceFileListsItsProjectsOnly() throws {
        let urls = try WorkspaceFileParser.projectURLs(
            in: Data(Fixtures.workspaceFile.utf8),
            workspaceURL: URL(fileURLWithPath: "/projects/Sample.xcworkspace")
        )
        XCTAssertEqual(urls.map(\.path), ["/projects/Sample.xcodeproj", "/elsewhere/Other.xcodeproj"])
    }

    func testXcodeListingForProjectAndWorkspace() throws {
        let project = try XcodeListParser.parse(Data(Fixtures.projectListing.utf8))
        XCTAssertEqual(project.schemes, ["Sample", "SampleKit", "PackageScheme"])
        XCTAssertEqual(project.configurations, ["Debug", "Release"])

        let workspace = try XcodeListParser.parse(Data(Fixtures.workspaceListing.utf8))
        XCTAssertEqual(workspace.schemes, ["Sample", "Pods-Sample"])
        XCTAssertEqual(workspace.targets, [])

        XCTAssertThrowsError(try XcodeListParser.parse(Data("{}".utf8)))
    }
}

final class ProjectReaderTests: XCTestCase {
    private var folder: TemporaryFolder!

    override func setUpWithError() throws {
        folder = try TemporaryFolder()
        try folder.write(Fixtures.projectFile, to: "Sample.xcodeproj/project.pbxproj")
        try folder.write(
            Fixtures.scheme(build: ["Sample.app"], runnable: "Sample.app"),
            to: "Sample.xcodeproj/xcshareddata/xcschemes/Sample.xcscheme"
        )
        try folder.write(
            Fixtures.scheme(build: ["SampleKit.framework"]),
            to: "Sample.xcodeproj/xcshareddata/xcschemes/SampleKit.xcscheme"
        )
        // A user's own scheme, and a user copy of a shared scheme that must not appear twice.
        try folder.write(
            Fixtures.scheme(build: ["SampleWidget.appex"]),
            to: "Sample.xcodeproj/xcuserdata/someone.xcuserdatad/xcschemes/Widget Only.xcscheme"
        )
        try folder.write(
            Fixtures.scheme(build: ["SampleKit.framework"]),
            to: "Sample.xcodeproj/xcuserdata/someone.xcuserdatad/xcschemes/Sample.xcscheme"
        )
    }

    override func tearDown() {
        folder.remove()
    }

    private func project() throws -> ProjectContainer {
        try ProjectContainer(url: folder.url.appendingPathComponent("Sample.xcodeproj"))
    }

    func testQuickSnapshotReadsFilesWithoutRunningAnyTool() throws {
        let runner = FakeToolRunner()
        let snapshot = try ProjectReader(toolRunner: runner).quickSnapshot(of: project())

        XCTAssertEqual(snapshot.schemes.map(\.name), ["Sample", "SampleKit", "Widget Only"])
        XCTAssertEqual(snapshot.schemes.map(\.kind), [.app, .framework, .appExtension])
        XCTAssertEqual(snapshot.schemes.map(\.isShared), [true, true, false])
        XCTAssertEqual(snapshot.targets.count, 5)
        XCTAssertEqual(snapshot.configurations, ["Debug", "Staging Debug", "Release"])
        XCTAssertEqual(snapshot.defaultConfiguration, "Release")
        XCTAssertEqual(snapshot.scheme(named: "Sample")?.runnable?.name, "Sample")
        XCTAssertTrue(runner.commands.isEmpty)
    }

    func testFullSnapshotAddsSchemesKnownOnlyToXcodebuild() async throws {
        let runner = FakeToolRunner()
        runner.onRun = { _ in ToolResult(exitCode: 0, stdout: Data(Fixtures.projectListing.utf8)) }
        let snapshot = try await ProjectReader(toolRunner: runner).fullSnapshot(of: project())

        XCTAssertEqual(snapshot.schemes.map(\.name), ["Sample", "SampleKit", "Widget Only", "PackageScheme"])
        XCTAssertEqual(snapshot.scheme(named: "PackageScheme")?.kind, .other)
        // The project file stays the source for configurations.
        XCTAssertEqual(snapshot.configurations, ["Debug", "Staging Debug", "Release"])
        XCTAssertEqual(runner.commands.map(\.text), ["xcodebuild -list -json -project \(try project().url.path)"])
    }

    func testFullSnapshotReportsAFailedListing() async throws {
        let runner = FakeToolRunner()
        runner.onRun = { _ in ToolResult(exitCode: 66, stderr: Data("xcodebuild: error: no project".utf8)) }
        do {
            _ = try await ProjectReader(toolRunner: runner).fullSnapshot(of: project())
            XCTFail("expected a failure")
        } catch let error as BuildDeskError {
            XCTAssertEqual(error, .toolFailed(tool: "xcodebuild", exitCode: 66, message: "xcodebuild: error: no project"))
        }
    }

    func testWorkspaceShowsTheSchemesAndTargetsOfItsProjects() throws {
        try folder.write(Fixtures.workspaceFile, to: "Sample.xcworkspace/contents.xcworkspacedata")
        try folder.write(
            Fixtures.scheme(build: ["Sample.app"]),
            to: "Sample.xcworkspace/xcshareddata/xcschemes/Everything.xcscheme"
        )
        let workspace = try ProjectContainer(url: folder.url.appendingPathComponent("Sample.xcworkspace"))
        let snapshot = try ProjectReader(toolRunner: FakeToolRunner()).quickSnapshot(of: workspace)

        // The project that does not exist on disk is skipped, not an error.
        XCTAssertEqual(snapshot.schemes.map(\.name), ["Everything", "Sample", "SampleKit", "Widget Only"])
        XCTAssertEqual(snapshot.targets.count, 5)
    }

    func testUnreadableProjectFileNamesTheFile() throws {
        try folder.write("not a property list {", to: "Sample.xcodeproj/project.pbxproj")
        XCTAssertThrowsError(try ProjectReader(toolRunner: FakeToolRunner()).quickSnapshot(of: project())) { error in
            guard case BuildDeskError.unreadableProject(let path, _) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertTrue(path.hasSuffix("Sample.xcodeproj/project.pbxproj"))
        }
    }

    func testOnlyProjectsAndWorkspacesAreAccepted() {
        XCTAssertThrowsError(try ProjectContainer(url: URL(fileURLWithPath: "/projects/Sample.txt"))) { error in
            XCTAssertEqual(error as? BuildDeskError, .unsupportedContainer(path: "/projects/Sample.txt"))
        }
        XCTAssertEqual(try Sample.container("App.xcworkspace").kind, .workspace)
        XCTAssertEqual(try Sample.container().name, "Sample")
    }
}

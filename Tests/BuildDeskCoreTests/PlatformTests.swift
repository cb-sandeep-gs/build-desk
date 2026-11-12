@testable import BuildDeskCore
import XCTest

final class PlatformTests: XCTestCase {
    /// A project that builds for iOS, with one target that sets its own SDK.
    private let projectFile = """
    {
    	objects = {
    		AA01 = { isa = PBXProject; buildConfigurationList = CL01; targets = (T001, T002, T003, ); };
    		CL01 = { isa = XCConfigurationList; buildConfigurations = (C001, ); };
    		C001 = { isa = XCBuildConfiguration; name = Debug; buildSettings = { SDKROOT = iphoneos; }; };
    		T001 = { isa = PBXNativeTarget; name = Sample; productType = "com.apple.product-type.application";
    			buildConfigurationList = CL02; };
    		CL02 = { isa = XCConfigurationList; buildConfigurations = (C002, ); };
    		C002 = { isa = XCBuildConfiguration; name = Debug; buildSettings = { PRODUCT_NAME = Sample; }; };
    		T002 = { isa = PBXNativeTarget; name = SampleWatch; productType = "com.apple.product-type.application";
    			buildConfigurationList = CL03; };
    		CL03 = { isa = XCConfigurationList; buildConfigurations = (C003, ); };
    		C003 = { isa = XCBuildConfiguration; name = Debug; buildSettings = { SDKROOT = watchos; }; };
    		T003 = { isa = PBXAggregateTarget; name = Docs; };
    	};
    	rootObject = AA01;
    }
    """

    func testTargetsTakeTheirPlatformFromTheirOwnSettingsOrTheProject() throws {
        let targets = try ProjectFileParser.parse(Data(projectFile.utf8)).targets

        XCTAssertEqual(targets.map(\.platform), [.iOS, .watchOS, .iOS])
    }

    func testPlatformNamesFromBuildSettingsAndDeviceTools() {
        XCTAssertEqual(Platform(sdkRoot: "iphonesimulator"), .iOS)
        XCTAssertEqual(Platform(sdkRoot: "appletvos"), .tvOS)
        XCTAssertEqual(Platform(sdkRoot: "xros"), .visionOS)
        XCTAssertEqual(Platform(sdkRoot: "macosx"), .macOS)
        XCTAssertNil(Platform(sdkRoot: "auto"))
        XCTAssertEqual(Platform(deviceName: "iPadOS"), .iOS)
        XCTAssertEqual(Platform(deviceName: "xrOS"), .visionOS)
        XCTAssertNil(Platform(deviceName: "bridgeOS"))
        XCTAssertEqual(Sample.phone.platformKind, .iOS)
    }

    func testDevicesAreMatchedToASchemeByPlatform() throws {
        let app = SchemeTarget(name: "Sample", productName: "Sample.app")
        let watch = SchemeTarget(name: "SampleWatch", productName: "SampleWatch.app")
        let snapshot = ProjectSnapshot(
            container: try Sample.container(),
            schemes: [],
            targets: [
                ProjectTarget(name: "Sample", kind: .application, platform: .iOS),
                ProjectTarget(name: "SampleWatch", kind: .application, platform: .watchOS),
                ProjectTarget(name: "Legacy", kind: .application),
            ],
            configurations: [],
            defaultConfiguration: nil
        )

        XCTAssertTrue(snapshot.canInstall(Scheme(name: "Sample", buildTargets: [app]), on: Sample.phone))
        XCTAssertFalse(snapshot.canInstall(Scheme(name: "SampleWatch", buildTargets: [watch]), on: Sample.phone))
        // An unknown platform is not a reason to hide a device.
        let legacy = Scheme(name: "Legacy", buildTargets: [SchemeTarget(name: "Legacy", productName: "Legacy.app")])
        XCTAssertTrue(snapshot.canInstall(legacy, on: Sample.phone))
        XCTAssertNil(snapshot.platform(of: Scheme(name: "Empty")))
    }

    func testExtensionSchemeIsInstallableOnlyWhenItAlsoBuildsItsApp() {
        let widget = SchemeTarget(name: "Widget", productName: "Widget.appex")
        let app = SchemeTarget(name: "Sample", productName: "Sample.app")

        XCTAssertTrue(Scheme(name: "Widget", buildTargets: [widget, app]).isInstallable)
        XCTAssertFalse(Scheme(name: "Widget", buildTargets: [widget]).isInstallable)
        XCTAssertFalse(Scheme(name: "Kit", buildTargets: [SchemeTarget(name: "Kit", productName: "Kit.framework")]).isInstallable)
    }
}

final class ProjectLocatorTests: XCTestCase {
    private func makeFolders(_ paths: [String]) throws -> TemporaryFolder {
        let folder = try TemporaryFolder()
        for path in paths {
            try FileManager.default.createDirectory(at: folder.url.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        return folder
    }

    func testAProjectOrWorkspaceIsUsedAsItIs() throws {
        let container = try ProjectLocator.container(at: URL(fileURLWithPath: "/projects/App.xcworkspace"))
        XCTAssertEqual(container.kind, .workspace)
    }

    func testAFolderIsSearchedNearestFirstWithWorkspacesAhead() throws {
        let folder = try makeFolders([
            "Source/App.xcodeproj", "Source/App.xcworkspace", "Tools/Helper.xcodeproj",
            "Source/Vendor/Deep/TooDeep.xcodeproj", ".hidden/Secret.xcodeproj",
        ])
        defer { folder.remove() }

        let found = ProjectLocator.containers(in: folder.url)

        XCTAssertEqual(found.map(\.url.lastPathComponent), ["App.xcworkspace", "App.xcodeproj", "Helper.xcodeproj"])
        XCTAssertEqual(try ProjectLocator.container(at: folder.url).url.lastPathComponent, "App.xcworkspace")
    }

    func testAFolderWithoutAProjectIsRefused() throws {
        let folder = try makeFolders(["Docs"])
        defer { folder.remove() }

        XCTAssertThrowsError(try ProjectLocator.container(at: folder.url)) { error in
            guard case BuildDeskError.unsupportedContainer = error else { return XCTFail("wrong error: \(error)") }
        }
    }
}

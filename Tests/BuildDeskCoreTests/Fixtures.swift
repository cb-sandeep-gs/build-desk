import Foundation

/// Tool output and project files in the shapes the real tools produce, with made-up names and
/// identifiers.
enum Fixtures {
    static func scheme(build: [String], tests: [String] = [], runnable: String? = nil) -> String {
        func reference(_ product: String) -> String {
            let target = (product as NSString).deletingPathExtension
            return """
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "AAAA"
               BuildableName = "\(product)" BlueprintName = "\(target)" ReferencedContainer = "container:Sample.xcodeproj">
            </BuildableReference>
            """
        }
        let entries = build.map { "<BuildActionEntry buildForRunning = \"YES\">\(reference($0))</BuildActionEntry>" }
        let testables = tests.map { "<TestableReference skipped = \"NO\">\(reference($0))</TestableReference>" }
        let runner = runnable.map { "<BuildableProductRunnable runnableDebuggingMode = \"0\">\(reference($0))</BuildableProductRunnable>" }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme LastUpgradeVersion = "2700" version = "1.3">
           <BuildAction parallelizeBuildables = "YES">
              <BuildActionEntries>\(entries.joined())</BuildActionEntries>
           </BuildAction>
           <TestAction buildConfiguration = "Debug">
              <Testables>\(testables.joined())</Testables>
           </TestAction>
           <LaunchAction buildConfiguration = "Debug">\(runner ?? "")</LaunchAction>
           <ProfileAction buildConfiguration = "Release">\(runner ?? "")</ProfileAction>
        </Scheme>
        """
    }

    static let projectFile = """
    // !$*UTF8*$!
    {
    	archiveVersion = 1;
    	objectVersion = 77;
    	objects = {
    		AA01 /* Project object */ = {
    			isa = PBXProject;
    			buildConfigurationList = CL01 /* Build configuration list */;
    			targets = (
    				T001 /* Sample */,
    				T002 /* SampleWidget */,
    				T003 /* SampleTests */,
    				T004 /* Docs */,
    				T005 /* SampleKit */,
    			);
    		};
    		CL01 = {
    			isa = XCConfigurationList;
    			buildConfigurations = (C001, C002, C003, );
    			defaultConfigurationName = Release;
    		};
    		C001 = { isa = XCBuildConfiguration; name = Debug; };
    		C002 = { isa = XCBuildConfiguration; name = "Staging Debug"; };
    		C003 = { isa = XCBuildConfiguration; name = Release; };
    		T001 = { isa = PBXNativeTarget; name = Sample; productType = "com.apple.product-type.application"; };
    		T002 = { isa = PBXNativeTarget; name = SampleWidget; productType = "com.apple.product-type.app-extension"; };
    		T003 = { isa = PBXNativeTarget; name = SampleTests; productType = "com.apple.product-type.bundle.unit-test"; };
    		T004 = { isa = PBXAggregateTarget; name = Docs; };
    		T005 = { isa = PBXNativeTarget; name = SampleKit; productType = "com.apple.product-type.framework"; };
    	};
    	rootObject = AA01 /* Project object */;
    }
    """

    static let workspaceFile = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Workspace version = "1.0">
       <FileRef location = "group:Sample.xcodeproj"></FileRef>
       <FileRef location = "group:Notes.md"></FileRef>
       <FileRef location = "absolute:/elsewhere/Other.xcodeproj"></FileRef>
    </Workspace>
    """

    static let projectListing = """
    {"project":{"configurations":["Debug","Release"],"name":"Sample","schemes":["Sample","SampleKit","PackageScheme"],
    "targets":["Sample","SampleTests"]}}
    """

    static let workspaceListing = """
    {"workspace":{"name":"Sample","schemes":["Sample","Pods-Sample"]}}
    """

    /// One wired phone (older and newer dictionaries), one phone this Mac only remembers, one
    /// phone described by the newer dictionary alone, and a simulator.
    static let deviceList = """
    {"info":{"jsonVersion":5,"outcome":"success"},"result":{"devices":[
      {"connectionProperties":{"pairingState":"paired","transportType":"wired","tunnelState":"disconnected"},
       "deviceProperties":{"bootState":"booted","name":"Test iPhone","osVersionNumber":"27.2"},
       "hardwareProperties":{"marketingName":"iPhone 17","platform":"iOS","productType":"iPhone18,3","reality":"physical",
         "udid":"00008000-0000000000000001"},
       "properties":{"connection":{"state":"disconnected","transportType":"wired"},
         "hardware":{"marketingName":"iPhone 17","platform":"iOS","reality":"physical","udid":"00008000-0000000000000001"},
         "software":{"osVersionNumber":{"components":[27,2,0],"stringValue":"27.2"}},
         "state":{"bootState":"booted","name":"Test iPhone"}}},
      {"connectionProperties":{"pairingState":"paired","tunnelState":"unavailable"},
       "deviceProperties":{"name":"Old iPhone","osVersionNumber":"26.1"},
       "hardwareProperties":{"marketingName":"iPhone 16","platform":"iOS","reality":"physical","udid":"00008000-0000000000000002"}},
      {"properties":{"connection":{"state":"connected","transportType":"localNetwork"},
         "hardware":{"marketingName":"iPad Pro","platform":"iOS","reality":"physical","udid":"00008000-0000000000000003"},
         "software":{"osVersionNumber":{"stringValue":"27.0"}},
         "state":{"bootState":"booted","name":"Test iPad"}}},
      {"connectionProperties":{"transportType":"sameMachine","tunnelState":"disconnected"},
       "deviceProperties":{"bootState":"shutdown","name":"iPhone 17 Pro"},
       "hardwareProperties":{"marketingName":"iPhone 17 Pro","platform":"iOS","reality":"simulated",
         "udid":"11111111-2222-3333-4444-555555555555"}}
    ]}}
    """

    static let simulatorList = """
    {"devices":{
      "com.apple.CoreSimulator.SimRuntime.iOS-27-2":[
        {"udid":"11111111-2222-3333-4444-555555555555","name":"iPhone 17 Pro","state":"Shutdown","isAvailable":true},
        {"udid":"11111111-2222-3333-4444-666666666666","name":"iPad Pro 11-inch","state":"Booted","isAvailable":true}],
      "com.apple.CoreSimulator.SimRuntime.tvOS-18-5":[
        {"udid":"11111111-2222-3333-4444-777777777777","name":"Apple TV 4K","state":"Shutdown","isAvailable":false,
         "availabilityError":"runtime profile not found"}]
    }}
    """

    static let buildSettings = """
    [{"action":"build","target":"SampleWidget","buildSettings":{"PRODUCT_TYPE":"com.apple.product-type.app-extension",
       "TARGET_BUILD_DIR":"/derived/Build/Products/Debug-iphoneos","WRAPPER_NAME":"SampleWidget.appex",
       "PRODUCT_BUNDLE_IDENTIFIER":"com.example.sample.widget"}},
     {"action":"build","target":"Sample","buildSettings":{"PRODUCT_TYPE":"com.apple.product-type.application",
       "TARGET_BUILD_DIR":"/derived/Build/Products/Debug-iphoneos","WRAPPER_NAME":"Sample.app",
       "PRODUCT_BUNDLE_IDENTIFIER":"com.example.sample"}}]
    """

    static let buildOutput: [String] = [
        "Command line invocation:",
        "Resolve Package Graph",
        "SwiftCompile normal arm64 /src/App/Home.swift (in target 'Sample' from project 'Sample')",
        "    cd /src",
        "/src/App/Home.swift:41:13: warning: 'load()' is deprecated",
        "/src/App/Home.swift:41:13: warning: 'load()' is deprecated",
        "Ld /derived/Sample.app/Sample normal (in target 'Sample' from project 'Sample')",
        "CodeSign /derived/Sample.app (in target 'Sample' from project 'Sample')",
        "** BUILD SUCCEEDED **",
    ]

    static let failingBuildOutput: [String] = [
        "SwiftCompile normal arm64 /src/App/Home.swift (in target 'Sample' from project 'Sample')",
        "/src/App/Home.swift:12:5: error: cannot find 'missing' in scope",
        "/src/App/Home.swift:12:5: error: cannot find 'missing' in scope",
        "error: No profiles for 'com.example.sample' were found",
        "** BUILD FAILED **",
    ]
}

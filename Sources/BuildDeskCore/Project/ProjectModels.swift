import Foundation

/// An Xcode project or workspace on disk.
public struct ProjectContainer: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case project
        case workspace
    }

    public let url: URL
    public let kind: Kind

    public init(url: URL) throws {
        switch url.pathExtension {
        case BuildDeskConstants.ProjectLayout.projectExtension: kind = .project
        case BuildDeskConstants.ProjectLayout.workspaceExtension: kind = .workspace
        default: throw BuildDeskError.unsupportedContainer(path: url.path)
        }
        self.url = url.standardizedFileURL
    }

    /// File name without the extension, shown as the project's title.
    public var name: String { url.deletingPathExtension().lastPathComponent }
}

/// What a target produces. Decides what can be done with it: an application can be installed, an
/// extension ships inside one, a framework can only be built.
public enum ProductKind: String, Sendable, Codable, CaseIterable {
    case application
    case watchApplication
    case appExtension
    case framework
    case library
    case unitTests
    case uiTests
    case other

    /// From the `productType` value of a target in `project.pbxproj`.
    public init(productType: String) {
        switch productType {
        case "com.apple.product-type.application": self = .application
        case let type where type.hasPrefix("com.apple.product-type.application.watchapp"): self = .watchApplication
        case let type where type.contains("app-extension") || type.contains("extensionkit-extension"): self = .appExtension
        case "com.apple.product-type.framework", "com.apple.product-type.framework.static": self = .framework
        case let type where type.hasPrefix("com.apple.product-type.library"): self = .library
        case "com.apple.product-type.bundle.unit-test": self = .unitTests
        case "com.apple.product-type.bundle.ui-testing": self = .uiTests
        default: self = .other
        }
    }

    /// From a product file name in a scheme file, such as "Sample.app". A scheme records only the
    /// file name, so unit and UI tests cannot be told apart here and both read as `unitTests`.
    public init(productFileName: String) {
        switch URL(fileURLWithPath: productFileName).pathExtension {
        case "app": self = .application
        case "appex": self = .appExtension
        case "framework": self = .framework
        case "a", "dylib", "o": self = .library
        case "xctest": self = .unitTests
        default: self = .other
        }
    }
}

/// A target of the project.
public struct ProjectTarget: Sendable, Equatable, Codable, Identifiable {
    public let name: String
    public let kind: ProductKind
    /// Nil when the project file does not say which SDK the target builds with.
    public let platform: Platform?

    public var id: String { name }

    public init(name: String, kind: ProductKind, platform: Platform? = nil) {
        self.name = name
        self.kind = kind
        self.platform = platform
    }
}

/// A target as a scheme refers to it.
public struct SchemeTarget: Sendable, Equatable, Codable {
    /// The target's name.
    public let name: String
    /// The file it produces, for example "Sample.app".
    public let productName: String
    public let kind: ProductKind

    public init(name: String, productName: String) {
        self.name = name
        self.productName = productName
        self.kind = ProductKind(productFileName: productName)
    }
}

/// What a scheme is for, which is how the app groups the scheme list.
public enum SchemeKind: String, Sendable, Codable, CaseIterable {
    /// Builds an app that can be installed and launched.
    case app
    /// Builds an extension, which ships inside its app.
    case appExtension
    /// Builds a framework or library: build only.
    case framework
    /// Only runs tests.
    case tests
    /// Known by name only (for example a Swift package scheme Xcode creates on its own).
    case other
}

/// A scheme and the targets it builds.
public struct Scheme: Sendable, Equatable, Codable, Identifiable {
    public let name: String
    public let kind: SchemeKind
    /// Targets built by the scheme's build action, in order; the first is its main product.
    public let buildTargets: [SchemeTarget]
    public let testTargets: [SchemeTarget]
    /// The product the scheme's Run action launches, when it has one.
    public let runnable: SchemeTarget?
    /// Shared schemes are checked in; the rest belong to one user.
    public let isShared: Bool

    public var id: String { name }

    public init(
        name: String,
        buildTargets: [SchemeTarget] = [],
        testTargets: [SchemeTarget] = [],
        runnable: SchemeTarget? = nil,
        isShared: Bool = true
    ) {
        self.name = name
        self.buildTargets = buildTargets
        self.testTargets = testTargets
        self.runnable = runnable
        self.isShared = isShared
        // A scheme named after one of its test targets exists to run those tests, even though it
        // builds, and can run, the app they are hosted in.
        let isNamedAfterItsTests = testTargets.contains { $0.name == name }
        self.kind = isNamedAfterItsTests ? .tests : Self.kind(buildTargets: buildTargets, testTargets: testTargets, runnable: runnable)
    }

    /// True when Build Desk can install what this scheme builds: an app, or an extension whose
    /// scheme also builds the app it ships in (as Xcode does when an extension scheme is run).
    public var isInstallable: Bool {
        switch kind {
        case .app: true
        case .appExtension: buildTargets.contains { $0.kind == .application }
        case .framework, .tests, .other: false
        }
    }

    /// The first build target decides: an extension scheme also builds its host app, but lists
    /// the extension first.
    private static func kind(buildTargets: [SchemeTarget], testTargets: [SchemeTarget], runnable: SchemeTarget?) -> SchemeKind {
        guard let main = buildTargets.first else { return testTargets.isEmpty ? .other : .tests }
        switch main.kind {
        case .application, .watchApplication:
            // A test scheme builds the app its tests run in, but has nothing to run itself.
            return runnable == nil && !testTargets.isEmpty ? .tests : .app
        case .appExtension: return .appExtension
        case .framework, .library: return .framework
        case .unitTests, .uiTests: return .tests
        case .other: return .other
        }
    }
}

/// Everything Build Desk knows about a project: what the scheme list, target list and
/// configuration picker are drawn from.
public struct ProjectSnapshot: Sendable, Equatable, Codable {
    public let container: ProjectContainer
    public let schemes: [Scheme]
    public let targets: [ProjectTarget]
    public let configurations: [String]
    /// The configuration command-line builds use when none is given.
    public let defaultConfiguration: String?
    /// The project's own Build Desk settings; empty when it has no `.builddesk.json`.
    public let config: ProjectConfig
    /// What is wrong with the project's `.builddesk.json`, when something is.
    public let configProblem: String?

    public init(
        container: ProjectContainer,
        schemes: [Scheme],
        targets: [ProjectTarget],
        configurations: [String],
        defaultConfiguration: String?,
        config: ProjectConfig = ProjectConfig(),
        configProblem: String? = nil
    ) {
        self.container = container
        self.schemes = schemes
        self.targets = targets
        self.configurations = configurations
        self.defaultConfiguration = defaultConfiguration
        self.config = config
        self.configProblem = configProblem
    }

    public func scheme(named name: String) -> Scheme? {
        schemes.first { $0.name == name }
    }
}

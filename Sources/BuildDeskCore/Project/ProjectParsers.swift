import Foundation

/// Reads an XML file into a flat list of elements, each with its attributes and the names of the
/// elements around it. Scheme and workspace files are small, so a flat list is all the parsers need.
final class XMLElementCollector: NSObject, XMLParserDelegate {
    struct Element {
        let name: String
        let attributes: [String: String]
        /// Enclosing element names, outermost first.
        let ancestors: [String]
    }

    private var stack: [String] = []
    private var elements: [Element] = []

    static func elements(in data: Data) throws -> [Element] {
        let collector = XMLElementCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else {
            throw parser.parserError ?? CocoaError(.fileReadCorruptFile)
        }
        return collector.elements
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        elements.append(Element(name: elementName, attributes: attributeDict, ancestors: stack))
        stack.append(elementName)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        stack.removeLast()
    }
}

/// Reads one `.xcscheme` file: which targets the scheme builds, tests and runs.
enum SchemeFileParser {
    private enum Element {
        static let buildableReference = "BuildableReference"
        static let buildEntry = "BuildActionEntry"
        static let testable = "TestableReference"
        static let launchAction = "LaunchAction"
        static let productRunnable = "BuildableProductRunnable"
    }

    private enum Attribute {
        static let targetName = "BlueprintName"
        static let productName = "BuildableName"
    }

    static func parse(_ data: Data, name: String, isShared: Bool) throws -> Scheme {
        var buildTargets: [SchemeTarget] = []
        var testTargets: [SchemeTarget] = []
        var runnable: SchemeTarget?

        for element in try XMLElementCollector.elements(in: data) where element.name == Element.buildableReference {
            guard let productName = element.attributes[Attribute.productName] else { continue }
            // Some scheme files leave the target name out of a reference; the product name without
            // its extension is the same name in practice.
            let targetName = element.attributes[Attribute.targetName]
                ?? URL(fileURLWithPath: productName).deletingPathExtension().lastPathComponent
            let target = SchemeTarget(name: targetName, productName: productName)
            // The same reference element appears under several actions; where it sits says what it means.
            if element.ancestors.contains(Element.buildEntry) {
                buildTargets.append(target)
            } else if element.ancestors.contains(Element.testable) {
                testTargets.append(target)
            } else if element.ancestors.contains(Element.launchAction), element.ancestors.contains(Element.productRunnable) {
                runnable = target
            }
        }
        return Scheme(name: name, buildTargets: buildTargets, testTargets: testTargets, runnable: runnable, isShared: isShared)
    }
}

/// The parts of `project.pbxproj` Build Desk needs: targets with their product types, and the
/// build configuration names.
struct ProjectFile: Equatable {
    let targets: [ProjectTarget]
    let configurations: [String]
    let defaultConfiguration: String?
}

enum ProjectFileParser {
    private enum Key {
        static let objects = "objects"
        static let rootObject = "rootObject"
        static let targets = "targets"
        static let name = "name"
        static let productType = "productType"
        static let configurationList = "buildConfigurationList"
        static let configurations = "buildConfigurations"
        static let defaultConfiguration = "defaultConfigurationName"
        static let buildSettings = "buildSettings"
        static let sdkRoot = "SDKROOT"
    }

    /// `project.pbxproj` is an old-style property list, which Foundation reads directly; reading
    /// it takes milliseconds where `xcodebuild -list` takes tens of seconds on a large project.
    static func parse(_ data: Data) throws -> ProjectFile {
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let root = plist as? [String: Any],
              let objects = root[Key.objects] as? [String: [String: Any]],
              let rootID = root[Key.rootObject] as? String,
              let project = objects[rootID] else {
            throw CocoaError(.propertyListReadCorrupt)
        }

        // A target that sets no SDK of its own builds with the project's.
        let projectPlatform = platform(ofConfigurationsOf: project, in: objects)
        let targetIDs = project[Key.targets] as? [String] ?? []
        let targets: [ProjectTarget] = targetIDs.compactMap { id in
            guard let target = objects[id], let name = target[Key.name] as? String else { return nil }
            // Aggregate and legacy targets have no product type.
            let kind = (target[Key.productType] as? String).map(ProductKind.init(productType:)) ?? .other
            let platform = platform(ofConfigurationsOf: target, in: objects) ?? projectPlatform
            return ProjectTarget(name: name, kind: kind, platform: platform)
        }

        let list = (project[Key.configurationList] as? String).flatMap { objects[$0] }
        let configurationIDs = list?[Key.configurations] as? [String] ?? []
        return ProjectFile(
            targets: targets,
            configurations: configurationIDs.compactMap { objects[$0]?[Key.name] as? String },
            defaultConfiguration: list?[Key.defaultConfiguration] as? String
        )
    }
}

extension ProjectFileParser {
    /// The SDK named by the build configurations of a project or target object, if any names one.
    private static func platform(ofConfigurationsOf owner: [String: Any], in objects: [String: [String: Any]]) -> Platform? {
        let list = (owner[Key.configurationList] as? String).flatMap { objects[$0] }
        let configurationIDs = list?[Key.configurations] as? [String] ?? []
        return configurationIDs.lazy
            .compactMap { objects[$0]?[Key.buildSettings] as? [String: Any] }
            .compactMap { $0[Key.sdkRoot] as? String }
            .compactMap(Platform.init(sdkRoot:))
            .first
    }
}

/// Finds the projects a workspace refers to.
enum WorkspaceFileParser {
    private static let fileReference = "FileRef"
    private static let location = "location"

    /// Returns project URLs listed in `contents.xcworkspacedata`. Locations are resolved against the
    /// workspace's folder; references nested in workspace groups with their own paths are not followed.
    static func projectURLs(in data: Data, workspaceURL: URL) throws -> [URL] {
        let folder = workspaceURL.deletingLastPathComponent()
        return try XMLElementCollector.elements(in: data)
            .filter { $0.name == fileReference }
            .compactMap { $0.attributes[location] }
            .compactMap { location -> URL? in
                // "group:App.xcodeproj", "container:App.xcodeproj" or "absolute:/path/App.xcodeproj".
                guard let separator = location.firstIndex(of: ":") else { return nil }
                let path = String(location[location.index(after: separator)...])
                let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
                return url.pathExtension == BuildDeskConstants.ProjectLayout.projectExtension ? url.standardizedFileURL : nil
            }
    }
}

/// Reads `xcodebuild -list -json`: the full scheme list, including schemes Xcode creates on its
/// own for Swift packages, which have no scheme file in the project.
enum XcodeListParser {
    struct Listing: Equatable {
        let schemes: [String]
        let targets: [String]
        let configurations: [String]
    }

    private struct Payload: Decodable {
        let project: Body?
        let workspace: Body?
    }

    private struct Body: Decodable {
        let schemes: [String]?
        let targets: [String]?
        let configurations: [String]?
    }

    static func parse(_ data: Data) throws -> Listing {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let body = payload.project ?? payload.workspace else {
            throw BuildDeskError.unexpectedOutput(tool: "xcodebuild -list", reason: "no project or workspace entry")
        }
        return Listing(schemes: body.schemes ?? [], targets: body.targets ?? [], configurations: body.configurations ?? [])
    }
}

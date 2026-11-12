import Foundation

/// Reads the live output of `xcodebuild test` for progress. Like build progress, this is text
/// meant for people, so only the long-standing "Test Case … passed" line is recognised and the
/// results themselves always come from the result bundle (`TestResultsParser`).
struct TestOutputParser {
    private static let classicPrefix = "Test Case '-["
    private static let classicNameEnd = "]' "
    private static let parallelPrefix = "Test case '"
    private static let parallelNameEnd = "' "
    private static let testingStarted = "Testing started"
    private static let startedWord = "started"

    /// xcodebuild prints a finished test in one of two shapes, depending on how the tests run:
    ///
    ///     Test Case '-[SampleTests.HomeTests testLoads]' passed (0.012 seconds).
    ///     Test case 'HomeTests.testLoads()' passed on 'Clone 1 of iPhone 17' (0.012 seconds)
    ///
    /// The second is used when tests run in parallel on simulator clones.
    func parse(_ line: String) -> TestEvent? {
        if line == Self.testingStarted { return .testingStarted }
        if line.hasPrefix(Self.classicPrefix) {
            return event(in: line, prefix: Self.classicPrefix, nameEnd: Self.classicNameEnd, separator: " ")
        }
        if line.hasPrefix(Self.parallelPrefix) {
            return event(in: line, prefix: Self.parallelPrefix, nameEnd: Self.parallelNameEnd, separator: ".")
        }
        return nil
    }

    /// Reads "<prefix><class><separator><test><nameEnd><verdict> …".
    private func event(in line: String, prefix: String, nameEnd: String, separator: Character) -> TestEvent? {
        let start = line.index(line.startIndex, offsetBy: prefix.count)
        guard let end = line.range(of: nameEnd, range: start..<line.endIndex),
              let split = line[start..<end.lowerBound].lastIndex(of: separator) else { return nil }
        let owner = line[start..<split]
        // "Module.Class" → "Class"; a class with no module is used as it is.
        let suite = owner.split(separator: ".").last.map(String.init) ?? String(owner)
        var name = String(line[line.index(after: split)..<end.lowerBound])
        if name.hasSuffix("()") { name.removeLast(2) }
        let verdict = line[end.upperBound...].prefix { $0.isLetter }
        if verdict == Self.startedWord { return .testingStarted }
        guard let status = TestCaseResult.Status(rawValue: String(verdict)) else { return nil }
        return .caseFinished(suite: suite, name: name, status: status)
    }
}

/// Reads `xcresulttool get test-results tests`: the tree of test plans, bundles, suites and
/// tests of a result bundle.
enum TestResultsParser {
    private enum NodeType {
        static let testCase = "Test Case"
        static let suite = "Test Suite"
        static let failure = "Failure Message"
        static let bundleSuffix = "test bundle"
    }

    private enum ResultName {
        static let passed = "Passed"
        static let skipped = "Skipped"
        /// A test that failed where a failure was expected counts as passed for the run.
        static let expectedFailure = "Expected Failure"
    }

    private struct Payload: Decodable {
        let testNodes: [Node]
    }

    private struct Node: Decodable {
        let name: String
        let nodeType: String
        let result: String?
        let durationInSeconds: Double?
        let sourceLocation: Location?
        let children: [Node]?
    }

    private struct Location: Decodable {
        let filePath: String?
        let lineNumber: Int?
    }

    static func parse(_ data: Data) throws -> [TestCaseResult] {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw BuildDeskError.unexpectedOutput(tool: "xcresulttool", reason: error.localizedDescription)
        }
        var results: [TestCaseResult] = []
        payload.testNodes.forEach { collect($0, bundle: "", suites: [], into: &results) }
        return results
    }

    /// Walks down the tree, remembering the bundle and suites above each test.
    private static func collect(_ node: Node, bundle: String, suites: [String], into results: inout [TestCaseResult]) {
        switch node.nodeType {
        case NodeType.testCase:
            let failures = (node.children ?? []).filter { $0.nodeType == NodeType.failure }.map {
                TestCaseResult.Failure(message: $0.name, file: $0.sourceLocation?.filePath, line: $0.sourceLocation?.lineNumber)
            }
            results.append(TestCaseResult(
                bundle: bundle,
                suite: suites.joined(separator: "/"),
                // "testLoads()" → "testLoads", which is what -only-testing takes.
                name: node.name.hasSuffix("()") ? String(node.name.dropLast(2)) : node.name,
                status: status(of: node.result),
                seconds: node.durationInSeconds ?? 0,
                failures: failures
            ))
        case NodeType.suite:
            node.children?.forEach { collect($0, bundle: bundle, suites: suites + [node.name], into: &results) }
        case let type where type.hasSuffix(NodeType.bundleSuffix):
            // "Unit test bundle" or "UI test bundle".
            node.children?.forEach { collect($0, bundle: node.name, suites: [], into: &results) }
        default:
            // The test plan, and anything a newer Xcode adds above the bundles.
            node.children?.forEach { collect($0, bundle: bundle, suites: suites, into: &results) }
        }
    }

    private static func status(of result: String?) -> TestCaseResult.Status {
        switch result {
        case ResultName.passed, ResultName.expectedFailure: .passed
        case ResultName.skipped: .skipped
        default: .failed
        }
    }
}

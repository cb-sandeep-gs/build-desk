import AppKit
import BuildDeskCore
import SwiftUI

/// The current or last test run: progress while it runs, then failures first and every test by class.
struct TestResultsView: View {
    let app: AppModel

    private var tests: TestRunModel { app.tests }

    var body: some View {
        if tests.phase != .idle {
            VStack(alignment: .leading, spacing: Layout.spacing) {
                HStack(spacing: Layout.spacing) {
                    Text("Tests").font(.headline)
                    Spacer()
                    if tests.isRunning {
                        Button("Stop", systemImage: "stop.fill") { tests.stop() }
                    } else if let failed = tests.summary?.failed, !failed.isEmpty {
                        Button("Re-run \(failed.count) Failed", systemImage: "arrow.clockwise") { app.rerunFailedTests() }
                            .disabled(app.runBlocker != nil)
                    }
                }
                status
                failures
                allTests
                if let logFile = tests.logFile, !tests.isRunning {
                    Button("Open Full Log") { NSWorkspace.shared.open(logFile) }.buttonStyle(.link).help(logFile.path)
                }
            }
            .padding(Layout.spacing)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
            .accessibilityIdentifier(AccessibilityID.testResults)
        }
    }

    @ViewBuilder private var status: some View {
        switch tests.phase {
        case .idle:
            EmptyView()
        case .building:
            VStack(alignment: .leading, spacing: Layout.spacingSmall) {
                ProgressView().progressViewStyle(.linear)
                let tasks = tests.buildTaskCount == 0 ? "" : " · \(tests.buildTaskCount.formatted()) tasks"
                Text("Building for testing\(tasks)").font(.callout).foregroundStyle(.secondary)
            }
        case .testing:
            VStack(alignment: .leading, spacing: Layout.spacingSmall) {
                ProgressView().progressViewStyle(.linear)
                Text(liveText).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        case .finished:
            if let summary = tests.summary { SummaryLine(summary: summary) }
        case .failed(let message):
            VStack(alignment: .leading, spacing: Layout.spacingSmall) {
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled)
                ForEach(tests.errors.prefix(Layout.diagnosticsShownAtOnce), id: \.self) { error in
                    Text(error.message).font(.callout).textSelection(.enabled)
                }
            }
        case .stopped:
            Label("Stopped.", systemImage: "stop.circle").foregroundStyle(.secondary)
        }
    }

    /// "42 run · 1 failed · CartTests.testTotal"
    private var liveText: String {
        let failed = tests.liveCounts[.failed] ?? 0
        return ["\(tests.liveTotal.formatted()) run", failed > 0 ? "\(failed.formatted()) failed" : nil, tests.latestTest]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// Failed tests with their reasons, which is what a person looks for first.
    @ViewBuilder private var failures: some View {
        if let failed = tests.summary?.failed, !failed.isEmpty {
            VStack(alignment: .leading, spacing: Layout.spacingSmall) {
                ForEach(failed.prefix(Layout.diagnosticsShownAtOnce)) { test in
                    HStack(alignment: .firstTextBaseline, spacing: Layout.spacingSmall) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red).frame(width: Layout.iconColumnWidth)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(test.suite).\(test.name)").font(.body.monospaced())
                            ForEach(Array(test.failures.enumerated()), id: \.offset) { _, failure in
                                Text(failure.message).font(.callout).textSelection(.enabled)
                                if let file = failure.file {
                                    Text("\(URL(fileURLWithPath: file).lastPathComponent)\(failure.line.map { ":\($0)" } ?? "")")
                                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .contextMenu {
                        Button("Run Only This Test") { app.runTests(only: [test.id]) }
                        Button("Run Only \(test.suite)") { app.runTests(only: ["\(test.bundle)/\(test.suite)"]) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var allTests: some View {
        if tests.summary != nil {
            DisclosureGroup("All tests by class") {
                LazyVStack(alignment: .leading, spacing: Layout.spacingSmall) {
                    ForEach(tests.suites) { suite in
                        HStack(spacing: Layout.spacingSmall) {
                            Image(systemName: suite.failedCount > 0 ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(suite.failedCount > 0 ? .red : .green)
                                .frame(width: Layout.iconColumnWidth)
                            Text(suite.suite).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            let failed = suite.failedCount
                            Text(failed > 0 ? "\(failed) of \(suite.cases.count) failed" : "\(suite.cases.count) passed or skipped")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .contextMenu {
                            Button("Run Only \(suite.suite)") { app.runTests(only: [suite.id]) }
                        }
                    }
                }
                .padding(.top, Layout.spacingSmall)
            }
        }
    }
}

/// "118 passed · 2 failed · 1 skipped · 1 m 4 s".
private struct SummaryLine: View {
    let summary: TestRunSummary

    var body: some View {
        HStack(spacing: Layout.spacing) {
            Label("\(summary.count(.passed).formatted()) passed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            if summary.count(.failed) > 0 {
                Label("\(summary.count(.failed).formatted()) failed", systemImage: "xmark.circle.fill").foregroundStyle(.red)
            }
            if summary.count(.skipped) > 0 {
                Label("\(summary.count(.skipped).formatted()) skipped", systemImage: "forward.circle").foregroundStyle(.secondary)
            }
            Spacer()
            Text(DurationText.short(summary.seconds)).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

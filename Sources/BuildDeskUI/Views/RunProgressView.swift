import AppKit
import BuildDeskCore
import SwiftUI

/// The current or last run: its steps, progress, result and the errors and warnings it produced.
struct RunProgressView: View {
    let run: RunModel
    @State private var showsAllWarnings = false

    var body: some View {
        if run.phase != .idle {
            VStack(alignment: .leading, spacing: Layout.spacing) {
                HStack(spacing: Layout.spacingSmall) {
                    ForEach(Array(run.steps.enumerated()), id: \.element) { index, step in
                        if index > 0 {
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        StepChip(step: step, status: run.statuses[step] ?? .pending)
                    }
                    Spacer()
                    elapsed
                }
                status
                diagnostics
            }
            .padding(Layout.spacing)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
            .accessibilityIdentifier(AccessibilityID.runStatus)
        }
    }

    /// Ticks while the run is in progress, then shows the final time.
    @ViewBuilder private var elapsed: some View {
        if let startedAt = run.startedAt {
            if let finishedAt = run.finishedAt {
                Text(DurationText.short(finishedAt.timeIntervalSince(startedAt)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(DurationText.short(context.date.timeIntervalSince(startedAt)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch run.phase {
        case .idle:
            EmptyView()
        case .running:
            VStack(alignment: .leading, spacing: Layout.spacingSmall) {
                if run.statuses[.build] == .running {
                    // A measured bar when a previous build tells how big this one is; else a busy bar.
                    if let progress = run.buildProgress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                Text(run.runningText).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        case .succeeded:
            Label(run.successText, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case .stopped:
            Label("Stopped.", systemImage: "stop.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var diagnostics: some View {
        if !run.errors.isEmpty {
            VStack(alignment: .leading, spacing: Layout.spacingSmall) {
                ForEach(run.errors, id: \.self) { DiagnosticRow(diagnostic: $0) }
            }
        }
        if !run.warnings.isEmpty {
            DisclosureGroup("\(run.warnings.count.formatted()) warnings") {
                VStack(alignment: .leading, spacing: Layout.spacingSmall) {
                    let shown = showsAllWarnings ? run.warnings : Array(run.warnings.prefix(Layout.diagnosticsShownAtOnce))
                    ForEach(shown, id: \.self) { DiagnosticRow(diagnostic: $0) }
                    if shown.count < run.warnings.count {
                        Button("Show all \(run.warnings.count.formatted())") { showsAllWarnings = true }
                            .buttonStyle(.link)
                    }
                }
                .padding(.top, Layout.spacingSmall)
            }
        }
        if let logFile = run.logFile, !run.isRunning {
            Button("Open Full Log") { NSWorkspace.shared.open(logFile) }
                .buttonStyle(.link)
                .help(logFile.path)
        }
    }
}

/// One step of the run with its state: waiting, in progress, done (with its time) or failed.
private struct StepChip: View {
    let step: PipelineStep
    let status: StepStatus

    var body: some View {
        HStack(spacing: 4) {
            switch status {
            case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
            case .running: ProgressView().controlSize(.mini)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
            Text(step.rawValue.capitalized)
            if case .done(let seconds) = status, seconds > 0 {
                Text(DurationText.short(seconds)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .font(.callout)
        .foregroundStyle(status == .pending ? .secondary : .primary)
        .accessibilityElement(children: .combine)
    }
}

/// One error or warning with where it is.
private struct DiagnosticRow: View {
    let diagnostic: Diagnostic

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Layout.spacingSmall) {
            Image(systemName: diagnostic.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(diagnostic.severity == .error ? .red : .yellow)
                .frame(width: Layout.iconColumnWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(diagnostic.message).textSelection(.enabled)
                if let location {
                    Text(location).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
        .contextMenu {
            Button("Copy Message") { copy(diagnostic.message) }
            if let file = diagnostic.file {
                Button("Copy File Path") { copy(file) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) }
            }
        }
    }

    /// "Home.swift:41" — the folder is in the copied path, not on screen.
    private var location: String? {
        guard let file = diagnostic.file else { return nil }
        let name = URL(fileURLWithPath: file).lastPathComponent
        return diagnostic.line.map { "\(name):\($0)" } ?? name
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

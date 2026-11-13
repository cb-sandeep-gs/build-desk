import BuildDeskCore
import SwiftUI

/// The project's go or no-go before a release: every gate with its result. Opening it runs the gates.
public struct ReleaseChecksSheet: View {
    let release: ReleaseModel
    @Environment(\.dismiss) private var dismiss

    public init(release: ReleaseModel) {
        self.release = release
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Layout.spacing) {
            Text("Release check").font(.title3.weight(.semibold))
            content
            HStack {
                Spacer()
                if release.checks != .loading {
                    Button("Run Again") { Task { await release.runChecks() } }
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Layout.spacingLarge)
        .frame(width: Layout.releaseSheetWidth)
        // A result on screen is kept; the gates run when there is none yet.
        .task { if release.checks.value == nil { await release.runChecks() } }
        .accessibilityIdentifier(AccessibilityID.releaseChecks)
    }

    @ViewBuilder private var content: some View {
        switch release.checks {
        case .idle, .loading:
            HStack(spacing: Layout.spacingSmall) {
                ProgressView().controlSize(.small)
                Text("Running the project's checks. This can take a minute or two.").font(.callout).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .loaded(let checks):
            verdict(checks)
            VStack(spacing: 0) {
                ForEach(Array(checks.gates.enumerated()), id: \.offset) { index, gate in
                    if index > 0 { Divider() }
                    GateRow(gate: gate)
                }
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
            if let hint = checks.hint {
                Text(hint).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func verdict(_ checks: ReleaseChecks) -> some View {
        let advisory = checks.gates.filter { !$0.passed && !$0.blocking }.count
        return HStack(spacing: Layout.spacingSmall) {
            Image(systemName: checks.isGo ? "checkmark.seal.fill" : "xmark.octagon.fill")
                .foregroundStyle(checks.isGo ? .green : .red)
            Text(checks.isGo ? "Go" : "No-go").font(.headline)
            if checks.isGo, advisory > 0 {
                Text("· \(advisory) advisory warning\(advisory == 1 ? "" : "s")").foregroundStyle(.secondary)
            }
        }
    }
}

private struct GateRow: View {
    let gate: ReleaseGate

    var body: some View {
        HStack(spacing: Layout.spacing) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: Layout.iconColumnWidth)
            Text(gate.title).fixedSize(horizontal: false, vertical: true)
            if !gate.blocking { Text("advisory").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if let seconds = gate.seconds {
                Text(DurationText.short(seconds)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Layout.spacing)
        .padding(.vertical, Layout.spacingSmall)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(gate.title), \(gate.passed ? "passed" : gate.blocking ? "failed" : "advisory warning")")
    }

    private var symbol: String {
        gate.passed ? "checkmark.circle.fill" : gate.blocking ? "xmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var color: Color {
        gate.passed ? .green : gate.blocking ? .red : .orange
    }
}

import BuildDeskCore
import Charts
import SwiftUI

/// After a build: the warnings that no earlier build of this scheme had.
struct NewWarningsView: View {
    /// Nil when there was nothing to compare with.
    let newWarnings: [Diagnostic]?

    var body: some View {
        if let newWarnings {
            if newWarnings.isEmpty {
                Label("No new warnings", systemImage: "checkmark.seal")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: Layout.spacingSmall) {
                    Label(
                        "\(newWarnings.count.formatted()) new warning\(newWarnings.count == 1 ? "" : "s") since earlier builds",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    ForEach(newWarnings.prefix(Layout.diagnosticsShownAtOnce), id: \.self) { warning in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(warning.message).textSelection(.enabled)
                            if let file = warning.file {
                                Text("\(URL(fileURLWithPath: file).lastPathComponent)\(warning.line.map { ":\($0)" } ?? "")")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.leading, Layout.iconColumnWidth + Layout.spacingSmall)
                    }
                }
                .padding(Layout.spacing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
                .accessibilityIdentifier(AccessibilityID.newWarnings)
            }
        }
    }
}

/// Past runs of the selected scheme: a build-time trend and the latest runs.
struct HistoryView: View {
    let records: [RunRecord]

    /// Successful builds, oldest first, for the trend.
    private var builds: [(index: Int, record: RunRecord)] {
        let successful = records.filter { $0.result == .succeeded && $0.buildSeconds != nil }.prefix(Layout.trendRunCount)
        return Array(successful.reversed().enumerated()).map { (index: $0.offset, record: $0.element) }
    }

    var body: some View {
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: Layout.spacingSmall) {
                Text("History").font(.headline)
                if builds.count > 1 { trend }
                VStack(spacing: 0) {
                    ForEach(Array(records.prefix(Layout.historyRowCount).enumerated()), id: \.element.id) { index, record in
                        if index > 0 { Divider() }
                        HistoryRow(record: record)
                    }
                }
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
            }
            .accessibilityIdentifier(AccessibilityID.history)
        }
    }

    /// One bar per build, so a build that suddenly takes longer stands out.
    private var trend: some View {
        Chart(builds, id: \.record.id) { item in
            // A named position per run (not a number), so each bar gets an equal share of the width.
            BarMark(x: .value("Run", String(item.index)), y: .value("Build time", item.record.buildSeconds ?? 0))
                .foregroundStyle(.tint)
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) { value in
                AxisGridLine()
                AxisValueLabel { Text(DurationText.short(value.as(Double.self) ?? 0)) }
            }
        }
        .frame(height: Layout.trendHeight)
        .accessibilityLabel("Build time of the last \(builds.count) builds")
    }
}

private struct HistoryRow: View {
    let record: RunRecord

    var body: some View {
        HStack(spacing: Layout.spacing) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: Layout.iconColumnWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title) · \(record.configuration) · \(record.deviceName)").lineLimit(1).truncationMode(.middle)
                HStack(spacing: Layout.spacingSmall) {
                    Text(record.date.formatted(.relative(presentation: .named)))
                    if let source = record.source {
                        Text("· \(source.branch) @ \(source.commit)\(source.hasLocalChanges ? " +changes" : "")")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(DurationText.short(record.totalSeconds)).monospacedDigit()
                if record.action != .installOnly, record.result == .succeeded {
                    Text(warningText).font(.caption).foregroundStyle((record.newWarningCount ?? 0) > 0 ? .orange : .secondary)
                }
            }
        }
        .padding(.horizontal, Layout.spacing)
        .padding(.vertical, Layout.spacingSmall)
    }

    private var title: String {
        switch (record.action, record.result) {
        case (_, .failed): "Failed"
        case (_, .stopped): "Stopped"
        case (.buildAndInstall, .succeeded): "Built and installed"
        case (.buildOnly, .succeeded): "Built"
        case (.installOnly, .succeeded): "Installed last build"
        }
    }

    private var symbol: String {
        switch record.result {
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .stopped: "stop.circle"
        }
    }

    private var color: Color {
        switch record.result {
        case .succeeded: .green
        case .failed: .red
        case .stopped: .secondary
        }
    }

    /// "657 warnings", or "657 warnings, 3 new" when some were not there before.
    private var warningText: String {
        let total = "\(record.warningCount.formatted()) warning\(record.warningCount == 1 ? "" : "s")"
        guard let new = record.newWarningCount, new > 0 else { return total }
        return "\(total), \(new.formatted()) new"
    }
}

/// How much disk the project's build output takes, with a way to free it.
struct BuildFolderView: View {
    let app: AppModel
    @State private var confirmsClean = false

    var body: some View {
        if let folder = app.buildFolder {
            VStack(alignment: .leading, spacing: Layout.spacingSmall) {
                Text("Build folder").font(.headline)
                HStack(spacing: Layout.spacing) {
                    Image(systemName: "internaldrive").frame(width: Layout.iconColumnWidth)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.buildBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Empty")
                        Text(folder.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    Spacer()
                    if app.isCleaningBuildFolder {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Clean…") { confirmsClean = true }
                            .disabled(folder.buildBytes == nil || app.run.isRunning)
                            .accessibilityIdentifier(AccessibilityID.cleanButton)
                    }
                }
                .padding(Layout.spacing)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
                if let message = app.buildFolderMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            }
            // Deleting build output costs a full rebuild, so it is never done on one click.
            .confirmationDialog("Delete this project's build output?", isPresented: $confirmsClean) {
                Button("Clean Build Folder", role: .destructive) { Task { await app.cleanBuildFolder() } }
            } message: {
                Text("The next build will be a full one, and Install Last Build will have nothing to install until then. "
                    + "Downloaded packages and the index are kept.")
            }
        }
    }
}

import BuildDeskCore
import SwiftUI

/// Release mode: where each app stands and its recent builds.
struct ReleaseView: View {
    @Bindable var release: ReleaseModel

    var body: some View {
        Group {
            switch release.state {
            case .idle, .loading:
                ProgressView("Reading the release status…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't read the release status", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await release.refresh() } }
                }
            case .loaded(let status):
                if status.apps.isEmpty {
                    ContentUnavailableView(
                        "No apps to release",
                        systemImage: "shippingbox",
                        description: Text("The project's release commands list no app.")
                    )
                } else {
                    content(status)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { release.activeAction != nil },
            set: { isShown in if !isShown { Task { await release.endAction() } } }
        )) {
            if let action = release.activeAction {
                ReleaseActionSheet(model: action) { Task { await release.endAction() } }
            }
        }
        // The first look at Release mode reads the status; later looks keep what is there.
        .task { if release.status == nil { await release.refresh() } }
        .accessibilityIdentifier(AccessibilityID.releaseView)
    }

    private func content(_ status: ReleaseStatus) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.spacingLarge) {
                header(status)
                if let app = release.selectedApp {
                    cards(app)
                    if release.canAct { actions(app) }
                    builds
                }
            }
            .frame(maxWidth: Layout.detailMaxWidth, alignment: .leading)
            .padding(Layout.spacingLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ status: ReleaseStatus) -> some View {
        HStack(spacing: Layout.spacing) {
            if status.apps.count > 1 {
                Picker("App", selection: $release.selectedAppID) {
                    ForEach(status.apps) { Text($0.name).tag(Optional($0.id)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } else if let app = status.apps.first {
                Text(app.name).font(.title2.weight(.semibold))
            }
            Spacer()
            if let head = status.head {
                // Which code the numbers below were counted from.
                Label(Self.describe(head), systemImage: "arrow.triangle.branch")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if release.isRefreshing { ProgressView().controlSize(.small) }
        }
    }

    /// Each button opens a sheet that previews the action; nothing is done from here.
    private func actions(_ app: ReleaseApp) -> some View {
        HStack(spacing: Layout.spacing) {
            Button("New Test Build…", systemImage: "paperplane") { release.begin(.testflight) }
                .buttonStyle(.borderedProminent)
                .disabled(app.tracks.isEmpty)
                .accessibilityIdentifier(AccessibilityID.newTestBuild)
            Button("Store Release…", systemImage: "bag") { release.begin(.store) }
                .disabled(!release.builds.contains { $0.kind == .testflight })
                .help("Mark the test build that was shipped as the store release")
            Spacer()
        }
        .controlSize(.large)
    }

    /// "develop @ a41c9e2 · local changes"
    private static func describe(_ head: ReleaseHead) -> String {
        let commit = String(head.commit.prefix(Layout.shortCommitLength))
        return "\(head.branch ?? "detached") @ \(commit)\(head.dirty == true ? " · local changes" : "")"
    }

    private func cards(_ app: ReleaseApp) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Layout.releaseCardMinWidth), spacing: Layout.spacing)], spacing: Layout.spacing) {
            SummaryCard(title: "Version in code", value: app.version, detail: nil)
            SummaryCard(
                title: "On the store", value: app.store?.version ?? "None",
                detail: app.commitsSinceStore.map { "\($0.formatted()) commits since" }
            )
            ForEach(app.tracks) { track in
                SummaryCard(
                    title: track.name, value: track.latest?.version ?? "No build yet",
                    detail: track.commitsSince.map { "\($0.formatted()) commits since" }
                )
            }
        }
    }

    @ViewBuilder private var builds: some View {
        VStack(alignment: .leading, spacing: Layout.spacingSmall) {
            Text("Builds").font(.headline)
            if release.builds.isEmpty {
                Text("No builds yet for this app.").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(release.builds.enumerated()), id: \.element.id) { index, build in
                        if index > 0 { Divider() }
                        BuildRow(
                            build: build, track: release.trackName(of: build), isOpen: release.selectedBuildID == build.id
                        ) {
                            release.selectedBuildID = release.selectedBuildID == build.id ? nil : build.id
                        }
                    }
                }
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
            }
        }
    }
}

/// One number of the summary: a label, a value and a line of context.
private struct SummaryCard: View {
    let title: String
    let value: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.title3.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            Text(detail ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(Layout.spacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
        .accessibilityElement(children: .combine)
    }
}

/// One build; a click opens its details in place.
private struct BuildRow: View {
    let build: ReleaseBuild
    let track: String
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.spacingSmall) {
            Button(action: toggle) {
                HStack(spacing: Layout.spacing) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.secondary).frame(width: Layout.iconColumnWidth)
                    Text(build.version).monospacedDigit()
                    Badge(text: track, symbol: build.kind == .store ? "bag" : "paperplane")
                    Spacer()
                    if let date = build.date {
                        Text(Date(timeIntervalSince1970: date).formatted(.relative(presentation: .named)))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(build.version), \(track)")
            if isOpen { details }
        }
        .padding(.horizontal, Layout.spacing)
        .padding(.vertical, Layout.spacingSmall)
    }

    private var details: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Layout.spacing, verticalSpacing: 2) {
            row("Name", build.id)
            if let commit = build.commit { row("Commit", String(commit.prefix(Layout.shortCommitLength))) }
            if let branch = build.branch { row("Branch", branch) }
            if let from = build.from { row("Shipped build", from) }
            if let notes = build.notes { row("Notes", notes) }
        }
        .font(.callout)
        .padding(.leading, Layout.iconColumnWidth + Layout.spacing)
        .padding(.bottom, Layout.spacingSmall)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(2)
        }
    }
}

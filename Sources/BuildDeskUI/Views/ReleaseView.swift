import BuildDeskCore
import SwiftUI

/// The Release page of one app: where it stands, its builds as a table grouped by version, and
/// the selected build's details and actions in an inspector beside the table.
struct ReleaseView: View {
    @Bindable var release: ReleaseModel
    let app: AppModel
    /// The build waiting for its build-and-install confirmation.
    @State private var pendingInstall: ReleaseBuild?

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
            case .loaded:
                if let selected = release.selectedApp {
                    content(selected)
                } else {
                    ContentUnavailableView(
                        "No apps to release", systemImage: "shippingbox",
                        description: Text("The project's release commands list no app.")
                    )
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
        .sheet(isPresented: $release.showsChecks) { ReleaseChecksSheet(release: release) }
        .confirmationDialog(
            "Build and install \(pendingInstall?.version ?? "this build")?",
            isPresented: Binding(get: { pendingInstall != nil }, set: { isShown in if !isShown { pendingInstall = nil } }),
            presenting: pendingInstall
        ) { build in
            Button("Build and Install") { Task { await app.installTagged(build) } }
            Button("Cancel", role: .cancel) {}
        } message: { build in
            Text(app.taggedInstallSummary(for: build) ?? "")
        }
        .task { if release.status == nil { await release.refresh() } }
        .accessibilityIdentifier(AccessibilityID.releaseView)
    }

    private func content(_ selected: ReleaseApp) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Layout.spacing) {
                    header(selected)
                    if let install = app.taggedInstall, app.showsTaggedInstall { TaggedInstallBanner(app: app, install: install) }
                    storeAlerts
                    ReleaseStages(app: selected, next: release.storeApp?.storeVersions?.first, latestState: latestState(of:))
                    filterBar(selected)
                }
                .padding(Layout.spacingLarge)
                Divider()
                ReleaseBuildTable(release: release)
            }
            .frame(minWidth: Layout.releaseTableMinWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let build = release.selectedBuild {
                Divider()
                ReleaseInspector(release: release, app: app, build: build) { pendingInstall = build }
                    .frame(width: Layout.inspectorWidth)
            }
        }
    }

    private func header(_ selected: ReleaseApp) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Layout.spacing) {
            Text(selected.name).font(.title.weight(.semibold))
            if let head = release.status?.head {
                // Which code the numbers below were counted from.
                Label(Self.describe(head), systemImage: "arrow.triangle.branch")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if release.isRefreshing { ProgressView().controlSize(.small) }
        }
    }

    /// What needs attention on the store's side, and the state of the connection to it.
    @ViewBuilder private var storeAlerts: some View {
        ForEach(release.storeApp?.alerts ?? [], id: \.message) { alert in
            Label(alert.message, systemImage: alert.isError ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.callout)
                .padding(Layout.spacing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    (alert.isError ? Color.red : Color.orange).opacity(0.15), in: RoundedRectangle(cornerRadius: Layout.cornerRadius)
                )
        }
        if let note = release.storeNote {
            Label(note, systemImage: "network").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    /// The filters on the left, the actions on the right; on two rows when one is too narrow, as
    /// with the inspector open in a small window.
    private func filterBar(_ selected: ReleaseApp) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Layout.spacing) {
                filterPicker.fixedSize()
                Spacer()
                actionButtons(selected)
            }
            VStack(alignment: .leading, spacing: Layout.spacingSmall) {
                HStack(spacing: Layout.spacing) {
                    actionButtons(selected)
                    Spacer()
                }
                filterPicker
            }
        }
    }

    @ViewBuilder private var filterPicker: some View {
        if release.filters.count > 1 {
            Picker("Show", selection: $release.filter) {
                ForEach(release.filters, id: \.self) { Text(release.title(of: $0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// Each action opens a sheet that previews it; nothing is done from here.
    @ViewBuilder
    private func actionButtons(_ selected: ReleaseApp) -> some View {
        if release.hasChecks {
            Button("Check…", systemImage: "checklist") { release.showsChecks = true }
                .fixedSize()
                .help("Run the project's go or no-go checks before a release")
                .accessibilityIdentifier(AccessibilityID.releaseChecks)
        }
        if release.canAct {
            Button("Store Release…", systemImage: "bag") { release.begin(.store) }
                .fixedSize()
                .disabled(!release.builds.contains { $0.kind == .testflight })
                .help("Mark the test build that was shipped as the store release")
            Button("New Build…", systemImage: "plus") { release.begin(.testflight) }
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .disabled(selected.tracks.isEmpty)
                .accessibilityIdentifier(AccessibilityID.newTestBuild)
        }
    }

    /// The live state of a track's newest build, for its stage tile.
    private func latestState(of track: ReleaseTrack) -> String? {
        track.latest.map { release.stateText(of: $0) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "develop @ a41c9e2 · local changes"
    private static func describe(_ head: ReleaseHead) -> String {
        let commit = String(head.commit.prefix(Layout.shortCommitLength))
        return "\(head.branch ?? "detached") @ \(commit)\(head.dirty == true ? " · local changes" : "")"
    }
}

/// The path a version takes, left to right: the code, each line of test builds, the store.
private struct ReleaseStages: View {
    let app: ReleaseApp
    /// The version being prepared on the store's side, when the store is connected.
    let next: ReleaseStoreVersion?
    let latestState: (ReleaseTrack) -> String?

    var body: some View {
        HStack(spacing: 0) {
            stage("In code", app.version, nil)
            ForEach(app.tracks) { track in
                Divider()
                stage(
                    track.name, track.latest?.version ?? "No build yet",
                    latestState(track) ?? track.commitsSince.map { "\($0.formatted()) commits since" }
                )
            }
            Divider()
            stage("App Store", app.store?.version ?? "None", storeDetail)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
    }

    /// What is coming next on the store when that is known, else how far the code has moved on.
    private var storeDetail: String? {
        if let next, let state = next.state { return "\(next.version): \(state)" }
        return app.commitsSinceStore.map { "\($0.formatted()) commits since" }
    }

    private func stage(_ title: String, _ value: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(detail ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(Layout.spacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The builds of the selected app, under the app version they belong to.
private struct ReleaseBuildTable: View {
    @Bindable var release: ReleaseModel

    var body: some View {
        let groups = release.buildGroups
        if groups.isEmpty {
            ContentUnavailableView(
                release.filter == .all ? "No builds yet" : "No builds match", systemImage: "shippingbox",
                description: Text(release.filter == .all ? "Create the first one with New Build." : "Choose All to see every build.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.builds) { build in
                                ReleaseBuildRow(
                                    build: build, track: release.trackName(of: build), store: release.storeBuild(for: build),
                                    state: release.stateText(of: build), isSelected: release.selectedBuildID == build.id
                                ) {
                                    release.selectedBuildID = release.selectedBuildID == build.id ? nil : build.id
                                }
                                Divider().padding(.leading, Layout.spacingLarge)
                            }
                        } header: {
                            header(group)
                        }
                    }
                }
            }
            .accessibilityIdentifier(AccessibilityID.releaseTable)
        }
    }

    private func header(_ group: ReleaseBuildGroup) -> some View {
        HStack(spacing: Layout.spacingSmall) {
            Text(group.id).font(.callout.weight(.semibold)).monospacedDigit()
            if group.isOnStore { Badge(text: "On the App Store", symbol: "bag") }
            Spacer()
            Text(group.builds.count == 1 ? "1 build" : "\(group.builds.count) builds").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, Layout.spacingLarge)
        .padding(.vertical, Layout.spacingSmall)
        .background(.bar)
    }
}

/// One build: version, track, state and age in columns. A click opens it in the inspector.
private struct ReleaseBuildRow: View {
    let build: ReleaseBuild
    let track: String
    let store: ReleaseStoreBuild?
    let state: String
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: Layout.spacing) {
                Text(build.version).monospacedDigit().fontWeight(isSelected ? .semibold : .regular)
                    .frame(width: Layout.tableVersionWidth, alignment: .leading)
                Text(track).foregroundStyle(.secondary).lineLimit(1)
                    .frame(
                        minWidth: Layout.tableTrackMinWidth, idealWidth: Layout.tableTrackWidth, maxWidth: Layout.tableTrackWidth,
                        alignment: .leading
                    )
                mark
                Text(state).foregroundStyle(store?.cloudState == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary)).lineLimit(1)
                Spacer(minLength: 0)
                if let date = build.date {
                    Text(Date(timeIntervalSince1970: date).formatted(.relative(presentation: .named)))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
            }
            .padding(.horizontal, Layout.spacingLarge)
            .padding(.vertical, Layout.spacingSmall + 1)
            .background(isSelected ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(build.version), \(track), \(state)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var mark: some View {
        Group {
            switch store?.cloudState {
            case .running: ProgressView().controlSize(.mini)
            case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case nil: Image(systemName: build.kind == .store ? "bag" : "circle.dotted").foregroundStyle(.tertiary)
            }
        }
        .frame(width: Layout.iconColumnWidth)
    }
}

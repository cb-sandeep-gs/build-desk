import BuildDeskCore
import SwiftUI

/// The selected build beside the table: what it is, its notes, and what can be done with it.
struct ReleaseInspector: View {
    let release: ReleaseModel
    let app: AppModel
    let build: ReleaseBuild
    /// Asks for the build-and-install confirmation.
    let install: () -> Void

    private var store: ReleaseStoreBuild? { release.storeBuild(for: build) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.spacing) {
                title
                facts
                if let notes = build.notes, !notes.isEmpty { notesBox(notes) }
                Divider()
                actions
            }
            .padding(Layout.spacingLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background.secondary)
        .accessibilityIdentifier(AccessibilityID.releaseInspector)
    }

    private var title: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(build.version).font(.title2.weight(.semibold)).monospacedDigit()
                let state = release.stateText(of: build)
                Text(state.isEmpty ? release.trackName(of: build) : "\(release.trackName(of: build)) · \(state)")
                    .font(.callout)
                    .foregroundStyle(store?.cloudState == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
            Spacer()
            Button("Close", systemImage: "xmark") { release.selectedBuildID = nil }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Close the details")
        }
    }

    private var facts: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Layout.spacing, verticalSpacing: Layout.spacingSmall) {
            row("Name", build.id)
            if let commit = build.commit { row("Commit", String(commit.prefix(Layout.shortCommitLength)), monospaced: true) }
            if let branch = build.branch { row("Branch", branch) }
            if let date = build.date { row("Made", Date(timeIntervalSince1970: date).formatted(date: .abbreviated, time: .shortened)) }
            if let from = build.from { row("Shipped build", from) }
            if let number = store?.number, !number.isEmpty { row("Store build", number) }
            if let workflow = store?.cloudDetail { row("Cloud", workflow) }
            if let groups = store?.groups, !groups.isEmpty { row("Testers", groups.formatted(.list(type: .and))) }
        }
        .font(.callout)
    }

    private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(monospaced ? .callout.monospaced() : .callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func notesBox(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: Layout.spacingSmall / 2) {
            Text("Notes").font(.callout).foregroundStyle(.secondary)
            Text(notes).font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Layout.spacingSmall + 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
        }
    }

    /// Full-width buttons, the most likely one first. A reason is shown under a button that can't be used.
    private var actions: some View {
        VStack(alignment: .leading, spacing: Layout.spacingSmall) {
            let blocker = app.taggedInstallBlocker(for: build)
            let device = app.selectedDevice?.name
            Button(action: install) {
                Label(device.map { "Install on \($0)…" } ?? "Build and Install…", systemImage: "arrow.down.to.line")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(blocker != nil)
            .help("Build this version from its tagged code on this Mac and install it")
            .accessibilityIdentifier(AccessibilityID.taggedInstallButton)
            if let blocker {
                Text(blocker).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if release.canAct, build.kind == .testflight {
                Button {
                    release.beginStoreRelease(of: build)
                } label: {
                    Label("Mark as Store Release…", systemImage: "bag").frame(maxWidth: .infinity)
                }
                .help("Record that this build is the one that shipped to the store")
            }
        }
        .controlSize(.large)
    }
}

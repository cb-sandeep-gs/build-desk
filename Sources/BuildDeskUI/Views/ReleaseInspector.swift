import AppKit
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
            if release.canDownload(build) { downloadRow }
            if release.offers(.notes, for: build) {
                wideButton("Edit What to Test…", "text.bubble", help: "Set the notes testers see for this build") {
                    release.begin(.notes, for: build)
                }
            }
            if release.offers(.testers, for: build) {
                wideButton("Add to Testers…", "person.2", help: "Add this build to the tester group its kind of build goes to") {
                    release.begin(.testers, for: build)
                }
            }
            if release.canAct, build.kind == .testflight {
                wideButton("Mark as Store Release…", "bag", help: "Record that this build is the one that shipped to the store") {
                    release.beginStoreRelease(of: build)
                }
            }
        }
        .controlSize(.large)
    }

    private func wideButton(_ title: String, _ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity)
        }
        .help(help)
    }

    /// The build's own file from the cloud build: fetch it, then show it or install it.
    @ViewBuilder private var downloadRow: some View {
        switch release.download(of: build)?.phase {
        case .running:
            HStack(spacing: Layout.spacingSmall) {
                ProgressView().controlSize(.small)
                Text("Downloading the app file…").font(.callout).foregroundStyle(.secondary)
            }
        case .done(let file):
            VStack(alignment: .leading, spacing: Layout.spacingSmall / 2) {
                Label(file.lastPathComponent, systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green).lineLimit(2).truncationMode(.middle)
                HStack(spacing: Layout.spacing) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    // The same path as a dropped app file: choose a device, then install.
                    Button("Install…") { Task { await app.openDropped(file) } }
                }
                .buttonStyle(.link)
                .controlSize(.regular)
            }
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            downloadButton
        case nil:
            downloadButton
        }
    }

    private var downloadButton: some View {
        wideButton("Download App File", "square.and.arrow.down", help: "Save the file the cloud build made, to install or share") {
            Task { await release.downloadArtifact(of: build) }
        }
        .accessibilityIdentifier(AccessibilityID.downloadArtifact)
    }
}

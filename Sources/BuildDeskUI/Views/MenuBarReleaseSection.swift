import BuildDeskCore
import SwiftUI

/// The menu bar's release part: one line per app with where its newest build stands.
struct MenuBarReleaseSection: View {
    let release: ReleaseModel
    /// Shows Release mode in the main window.
    let openRelease: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.spacingSmall) {
            HStack {
                Text("Releases").font(.caption).foregroundStyle(.secondary)
                if release.isRefreshing { ProgressView().controlSize(.mini) }
                Spacer()
                Button("Open Release", action: openRelease).buttonStyle(.link)
            }
            ForEach(release.menuLines) { line in
                ReleaseLineRow(line: line)
            }
            // Said only when the live part is missing, so the lines above are not read as complete.
            if let note = release.storeNote, release.store.value?.connected != true, !release.isRefreshing {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier(AccessibilityID.menuBarReleases)
    }
}

private struct ReleaseLineRow: View {
    let line: ReleaseMenuLine

    @ViewBuilder private var mark: some View {
        switch line.mark {
        case .running: ProgressView().controlSize(.small)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .none: Image(systemName: "shippingbox").foregroundStyle(.tertiary)
        }
    }

    var body: some View {
        HStack(spacing: Layout.spacingSmall) {
            mark.frame(width: Layout.iconColumnWidth)
            VStack(alignment: .leading, spacing: 1) {
                Text(line.title).lineLimit(1)
                Text(line.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
        }
        .padding(Layout.spacingSmall)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
        .accessibilityElement(children: .combine)
    }
}

/// The setting that turns the release watch on and off.
struct ReleaseWatchSettings: View {
    @Bindable var watch: ReleaseWatchModel

    var body: some View {
        Section {
            Toggle("Watch release builds", isOn: $watch.isEnabled)
                .accessibilityIdentifier(AccessibilityID.releaseWatchToggle)
        } footer: {
            VStack(alignment: .leading, spacing: Layout.spacingSmall) {
                Text("For a project that can tell its store state, Build Desk reads it every minute while a cloud build "
                    + "is running and every 15 minutes otherwise. The menu bar shows it, and you are told when a cloud "
                    + "build ends or a build reaches testers. It only reads; nothing is changed.")
                if let lastChecked = watch.lastChecked {
                    Text("Last read: \(lastChecked.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

import BuildDeskCore
import SwiftUI

/// The Activity page: every past run of the project, and the files Build Desk and Xcode keep on
/// disk for it, with the ways to free them.
struct ActivityView: View {
    let app: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.spacingLarge) {
                Text("Activity").font(.title.weight(.semibold))
                if app.history.isEmpty {
                    ContentUnavailableView(
                        "No runs yet", systemImage: "clock.arrow.circlepath",
                        description: Text("Builds, installs and their times show here once you have run one.")
                    )
                } else {
                    HistoryView(records: app.history, title: "Runs", rowLimit: Layout.activityRowCount, showsScheme: true)
                }
                storage
            }
            .frame(maxWidth: Layout.detailMaxWidth, alignment: .leading)
            .padding(Layout.spacingLarge)
            .frame(maxWidth: .infinity)
        }
        .task { await app.refreshTaggedSource() }
        .accessibilityIdentifier(AccessibilityID.activityView)
    }

    @ViewBuilder private var storage: some View {
        if app.buildFolder != nil || app.taggedBytes != nil {
            VStack(alignment: .leading, spacing: Layout.spacing) {
                BuildFolderView(app: app)
                TaggedSourceLine(app: app)
            }
        }
    }
}

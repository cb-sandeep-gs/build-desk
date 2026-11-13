import BuildDeskCore
import SwiftUI

/// One thing on the store's side that needs attention: what happened, what to do about it when
/// the project knows, and the two ways forward (open the page where it is fixed, read again).
struct ReleaseAlertBanner: View {
    let alert: ReleaseAlert
    /// True while the store is being read again.
    let isRetrying: Bool
    let retry: () -> Void

    private var tint: Color { alert.isError ? .red : .orange }

    var body: some View {
        HStack(alignment: .top, spacing: Layout.spacing) {
            Image(systemName: alert.isError ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: Layout.spacingSmall) {
                Text(alert.message).fixedSize(horizontal: false, vertical: true)
                if let help = alert.help {
                    Text(help).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            // The words take the row's width; the two buttons keep their own size beside them.
            .frame(maxWidth: .infinity, alignment: .leading)
            if let page = alert.webPage {
                Link("Open…", destination: page)
                    .help(page.absoluteString)
                    .accessibilityIdentifier(AccessibilityID.releaseAlertOpen)
            }
            Button("Try Again", action: retry)
                .buttonStyle(.link)
                .disabled(isRetrying)
                .help("Read the store again")
                .accessibilityIdentifier(AccessibilityID.releaseAlertRetry)
        }
        .font(.callout)
        .padding(Layout.spacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
        .accessibilityElement(children: .contain)
    }
}

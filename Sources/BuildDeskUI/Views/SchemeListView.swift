import BuildDeskCore
import SwiftUI

/// The sidebar: every scheme, grouped by what can be done with it.
struct SchemeListView: View {
    @Bindable var project: ProjectModel

    var body: some View {
        Group {
            switch project.state {
            case .idle, .loading:
                ProgressView("Reading project…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't read the project", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await project.load() } }
                }
            case .loaded:
                list
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    private var list: some View {
        List(selection: $project.selectedSchemeName) {
            ForEach(project.groups) { group in
                Section(group.title) {
                    ForEach(group.schemes) { scheme in
                        SchemeRow(scheme: scheme, platform: project.snapshot?.platform(of: scheme))
                            .tag(Optional(scheme.name))
                    }
                }
            }
        }
        .searchable(text: $project.filter, placement: .sidebar, prompt: "Filter schemes")
        .overlay {
            if project.groups.isEmpty {
                // Either the filter matches nothing or the project has no schemes at all.
                if project.filter.isEmpty {
                    ContentUnavailableView(
                        "No schemes",
                        systemImage: "square.dashed",
                        description: Text("This project has no shared schemes. Share one in Xcode's scheme manager.")
                    )
                } else {
                    ContentUnavailableView.search(text: project.filter)
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.schemeList)
    }

    /// Swift package schemes have no scheme file; listing them needs `xcodebuild`, which is slow,
    /// so it is offered instead of done on every open.
    @ViewBuilder private var footer: some View {
        if project.snapshot != nil, !project.hasAllSchemes {
            VStack(alignment: .leading, spacing: Layout.spacingSmall) {
                Divider()
                Group {
                    if project.isLoadingAllSchemes {
                        HStack(spacing: Layout.spacingSmall) {
                            ProgressView().controlSize(.small)
                            Text("Asking Xcode for package schemes…")
                        }
                    } else {
                        Button("Show Package Schemes") { Task { await project.loadAllSchemes() } }
                            .buttonStyle(.link)
                            .help("Also list schemes Xcode creates for Swift packages. This can take half a minute.")
                    }
                    if let error = project.allSchemesError {
                        Text(error).foregroundStyle(.red).lineLimit(3)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Layout.spacing)
                .padding(.bottom, Layout.spacingSmall)
            }
            .background(.bar)
        }
    }
}

private struct SchemeRow: View {
    let scheme: Scheme
    let platform: Platform?

    var body: some View {
        Label {
            Text(scheme.name)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            // An app shows the device it runs on; other kinds show what they are.
            Image(systemName: scheme.kind == .app ? (platform?.symbol ?? scheme.kind.symbol) : scheme.kind.symbol)
        }
        .help(scheme.buildTargets.map(\.productName).joined(separator: ", "))
    }
}

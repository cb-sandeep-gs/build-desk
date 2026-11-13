import BuildDeskCore
import SwiftUI

/// The sidebar: every scheme grouped by what can be done with it, then the apps of the release
/// workflow and the activity page. It is the same on every page, so the window keeps its shape.
struct SchemeListView: View {
    @Bindable var app: AppModel
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
        List(selection: $app.sidebarSelection) {
            ForEach(project.groups) { group in
                Section(group.title) {
                    ForEach(group.schemes) { scheme in
                        SchemeRow(scheme: scheme, platform: project.snapshot?.platform(of: scheme))
                            .tag(Optional(SidebarItem.scheme(scheme.name)))
                    }
                }
            }
            if app.release != nil { releaseSection }
            Section("Activity") {
                Label("Runs and storage", systemImage: "clock.arrow.circlepath")
                    .badge(Text(app.storageBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""))
                    .tag(Optional(SidebarItem.activity))
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

    /// One row per app the project ships, with its version; a spinner until the status is read.
    @ViewBuilder private var releaseSection: some View {
        Section("Release") {
            if app.releaseApps.isEmpty {
                switch app.release?.state {
                case .failed(let message):
                    Label("Couldn't read the status", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).help(message)
                default:
                    Label("Reading the status…", systemImage: "shippingbox").foregroundStyle(.secondary)
                }
            }
            ForEach(app.releaseApps) { releaseApp in
                Label(releaseApp.name, systemImage: "shippingbox")
                    .badge(Text(releaseApp.version))
                    .tag(Optional(SidebarItem.releaseApp(releaseApp.id)))
            }
        }
    }

    /// Swift package schemes have no scheme file; listing them needs `xcodebuild`, which is slow,
    /// so it is offered instead of done on every open.
    @ViewBuilder private var footer: some View {
        if let snapshot = project.snapshot, !project.hasAllSchemes || project.hiddenSchemeCount > 0 || snapshot.configProblem != nil {
            VStack(alignment: .leading, spacing: Layout.spacingSmall) {
                Divider()
                Group {
                    if let problem = snapshot.configProblem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .lineLimit(4)
                    }
                    if project.hiddenSchemeCount > 0 {
                        Toggle("Show \(project.hiddenSchemeCount) hidden", isOn: $project.showsHiddenSchemes)
                            .toggleStyle(.checkbox)
                            .help("Schemes this project's \(ProjectConfig.fileName) hides")
                    }
                    if project.hasAllSchemes {
                        EmptyView()
                    } else
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

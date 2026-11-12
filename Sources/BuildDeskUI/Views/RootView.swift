import AppKit
import BuildDeskCore
import SwiftUI

/// The window's content: the welcome screen until a project is open, then the project.
public struct BuildDeskRootView: View {
    private let app: AppModel
    private let autoloads: Bool

    /// - Parameter autoloads: reopen the last project and keep devices fresh. Off for the demo and
    ///   snapshots, which set their own state.
    public init(app: AppModel, autoloads: Bool = true) {
        self.app = app
        self.autoloads = autoloads
    }

    public var body: some View {
        Group {
            if let project = app.project {
                ProjectView(app: app, project: project)
            } else {
                WelcomeView(app: app)
            }
        }
        .frame(minWidth: Layout.windowMinWidth, minHeight: Layout.windowMinHeight)
        // A project, its folder, a .app or an .ipa can be dropped anywhere on the window.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await app.openDropped(url) }
            return true
        }
        .sheet(isPresented: Binding(
            get: { app.pendingArtifact != nil },
            set: { isShown in if !isShown { app.dismissPendingArtifact() } }
        )) {
            if let artifact = app.pendingArtifact { ArtifactInstallSheet(app: app, artifact: artifact) }
        }
        // The welcome screen shows a failed open in place; with a project open it needs an alert.
        .alert("Couldn't open that", isPresented: Binding(
            get: { app.openError != nil && app.project != nil },
            set: { isShown in if !isShown { app.clearOpenError() } }
        )) {
            Button("OK") { app.clearOpenError() }
        } message: {
            Text(app.openError ?? "")
        }
        .task {
            guard autoloads else { return }
            await app.restoreLastProject()
        }
        .task {
            guard autoloads else { return }
            // Runs for as long as the window exists and stops with it.
            while !Task.isCancelled {
                await app.refreshEnvironment()
                try? await Task.sleep(for: DeviceListModel.pollInterval)
            }
        }
    }
}

/// Asks the user for a project, a workspace, or the folder that holds one.
@MainActor
public enum ProjectPicker {
    public static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Open a project"
        panel.message = "Choose an Xcode project, a workspace, the folder that contains one, or a built .app or .ipa to install."
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    public static func chooseAndOpen(in app: AppModel) {
        guard let url = choose() else { return }
        Task { await app.openDropped(url) }
    }
}

/// Shown when no project is open: open one, or pick a recent one.
struct WelcomeView: View {
    let app: AppModel

    var body: some View {
        VStack(spacing: Layout.spacingLarge) {
            Image(systemName: "hammer.circle.fill")
                .font(.system(size: Layout.heroIconSize))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(spacing: Layout.spacingSmall) {
                Text("Build Desk").font(.largeTitle.weight(.semibold))
                Text("Build, install and launch any scheme on your device, without opening Xcode. Drop a project, or a built app, here.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Open Project…") { ProjectPicker.chooseAndOpen(in: app) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(AccessibilityID.openProject)

            if let error = app.openError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            if !app.recentProjects.isEmpty { recents }
        }
        .frame(maxWidth: Layout.welcomeWidth)
        .padding(Layout.spacingLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: Layout.spacingSmall) {
            Text("Recent").font(.headline)
            ForEach(app.recentProjects, id: \.path) { url in
                Button {
                    Task { await app.open(url) }
                } label: {
                    HStack {
                        Image(systemName: "folder").frame(width: Layout.iconColumnWidth)
                        VStack(alignment: .leading) {
                            Text(url.deletingPathExtension().lastPathComponent)
                            Text(url.deletingLastPathComponent().path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An open project: scheme list on the left, the selected scheme on the right.
struct ProjectView: View {
    @Bindable var app: AppModel
    @Bindable var project: ProjectModel

    var body: some View {
        Group {
            if app.mode == .release, let release = app.release {
                ReleaseView(release: release)
            } else {
                NavigationSplitView {
                    SchemeListView(project: project)
                        .navigationSplitViewColumnWidth(
                            min: Layout.sidebarMinWidth, ideal: Layout.sidebarIdealWidth, max: Layout.sidebarMaxWidth
                        )
                } detail: {
                    SchemeDetailView(app: app, project: project)
                }
            }
        }
        .navigationTitle(project.container.name)
        .navigationSubtitle(project.container.url.deletingLastPathComponent().lastPathComponent)
        .toolbar {
            // Only a project with release commands has a second mode to switch to.
            if app.release != nil {
                ToolbarItem(placement: .principal) {
                    Picker("Mode", selection: $app.mode) {
                        ForEach(WindowMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier(AccessibilityID.modePicker)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Open Project…", systemImage: "folder") { ProjectPicker.chooseAndOpen(in: app) }
                    .help("Open another project")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Reload", systemImage: "arrow.clockwise") {
                    Task {
                        await project.load()
                        await app.refreshEnvironment()
                        await app.release?.refresh()
                    }
                }
                .help("Reload schemes, devices and the release status")
            }
        }
    }
}

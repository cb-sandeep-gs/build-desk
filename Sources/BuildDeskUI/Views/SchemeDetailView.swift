import BuildDeskCore
import SwiftUI

/// The Build page of the selected scheme: the actions, what is on the device, how the last build
/// went, the run in progress and the runs before it. The device and the configuration are chosen
/// in the toolbar.
struct SchemeDetailView: View {
    @Bindable var app: AppModel
    @Bindable var project: ProjectModel
    @State private var confirmsClean = false

    var body: some View {
        if let scheme = project.selectedScheme {
            ScrollView {
                VStack(alignment: .leading, spacing: Layout.spacingLarge) {
                    if app.isXcodeOpen { xcodeWarning }
                    titleRow(scheme)
                    actions(scheme)
                    facts(scheme)
                    RunProgressView(run: app.run)
                    TestResultsView(app: app)
                    if app.run.phase == .succeeded { NewWarningsView(newWarnings: app.newWarnings) }
                    ConsoleView(console: app.console)
                    HistoryView(records: app.historyForSelectedScheme)
                    targets(scheme)
                }
                .frame(maxWidth: Layout.detailMaxWidth, alignment: .leading)
                .padding(Layout.spacingLarge)
                // Centered, so a wide window has even margins instead of one empty half.
                .frame(maxWidth: .infinity)
            }
            // Deleting build output costs a full rebuild, so it is never done on one click.
            .confirmationDialog("Delete this project's build output?", isPresented: $confirmsClean) {
                Button("Clean Build Folder", role: .destructive) { Task { await app.cleanBuildFolder() } }
            } message: {
                Text("The next build will be a full one, and Install Last Build will have nothing to install until then. "
                    + "Downloaded packages and the index are kept.")
            }
        } else {
            ContentUnavailableView(
                "Choose a scheme",
                systemImage: "sidebar.left",
                description: Text("Pick a scheme from the list to build and install it.")
            )
        }
    }

    // MARK: - Sections

    private var xcodeWarning: some View {
        Label("Xcode is open. Builds from Build Desk can fail while Xcode holds the build folder; quit Xcode first.",
              systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .padding(Layout.spacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
    }

    private func titleRow(_ scheme: Scheme) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Layout.spacing) {
            Text(scheme.name)
                .font(.title.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Badge(text: scheme.kind.label, symbol: scheme.kind.symbol)
            if let platform = project.snapshot?.platform(of: scheme) {
                Badge(text: platform.rawValue, symbol: platform.symbol)
            }
            Spacer()
            Button(app.isSelectionPinned ? "Unpin" : "Pin", systemImage: app.isSelectionPinned ? "pin.fill" : "pin") {
                app.togglePinForSelection()
            }
            .disabled(app.pinForSelection == nil)
            .help(app.isSelectionPinned
                ? "Remove this scheme and device from the menu bar"
                : "Keep this scheme and device in the menu bar, to build and install in one click")
            .accessibilityIdentifier(AccessibilityID.pinButton)
        }
    }

    /// Three facts a person checks before building: what the device has, how the last build went,
    /// and how much disk the build output takes.
    private func facts(_ scheme: Scheme) -> some View {
        // Equal tiles across the whole width, whatever their number.
        HStack(alignment: .top, spacing: Layout.spacing) {
            if scheme.isInstallable { deviceCard }
            lastBuildCard
            if let folder = app.buildFolder {
                StatCard(
                    title: "Build files",
                    value: folder.buildBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Empty",
                    detail: app.buildFolderMessage ?? "Kept by Xcode for this project"
                ) {
                    if app.isCleaningBuildFolder {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Clean…") { confirmsClean = true }
                            .disabled(folder.buildBytes == nil || app.run.isRunning)
                            .accessibilityIdentifier(AccessibilityID.cleanButton)
                    }
                }
            }
        }
    }

    @ViewBuilder private var deviceCard: some View {
        let title = app.selectedDevice.map { "On \($0.name)" } ?? "On the device"
        if let record = app.lastInstall {
            // The branch (or the release build's name) is the fact; the commit and the age are context.
            let commit = record.source.map { "\($0.commit)\($0.hasLocalChanges ? " with local changes" : "") · " } ?? ""
            StatCard(
                title: title, value: record.source?.branch ?? "Installed",
                detail: "\(commit)\(record.date.formatted(.relative(presentation: .named))) · \(record.configuration)"
            )
            .help("What Build Desk last installed for this scheme on this device, and the code it was built from")
        } else {
            StatCard(title: title, value: "Nothing yet", detail: "Not installed from here so far")
        }
    }

    @ViewBuilder private var lastBuildCard: some View {
        if let record = app.historyForSelectedScheme.first(where: { $0.buildSeconds != nil }) {
            let warnings = "\(record.warningCount.formatted()) warning\(record.warningCount == 1 ? "" : "s")"
            let new = record.newWarningCount.map { $0 > 0 ? " · \($0.formatted()) new" : " · none new" } ?? ""
            StatCard(
                title: record.result == .succeeded ? "Last build" : "Last build failed",
                value: DurationText.short(record.buildSeconds ?? record.totalSeconds), detail: warnings + new
            )
        } else {
            StatCard(title: "Last build", value: "None yet", detail: "The first build is a full one")
        }
    }

    private func actions(_ scheme: Scheme) -> some View {
        VStack(alignment: .leading, spacing: Layout.spacingSmall) {
            HStack(spacing: Layout.spacing) {
                if app.run.isRunning {
                    Button("Stop", systemImage: "stop.fill", role: .destructive) { app.run.stop() }
                        .controlSize(.large)
                        .accessibilityIdentifier(AccessibilityID.stopButton)
                } else {
                    Button(scheme.isInstallable ? "Build and Install" : "Build", systemImage: "play.fill") {
                        app.runSelected(.buildAndInstall)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(app.runBlocker != nil)
                    .accessibilityIdentifier(AccessibilityID.runButton)

                    if scheme.isInstallable {
                        Button("Build Only") { app.runSelected(.buildOnly) }
                            .controlSize(.large)
                            .disabled(app.runBlocker != nil)
                            .accessibilityIdentifier(AccessibilityID.buildOnlyButton)
                        Button("Install Last Build") { app.runSelected(.installOnly) }
                            .controlSize(.large)
                            .disabled(app.runBlocker != nil)
                            .help("Install the app the last build left behind, without rebuilding")
                            .accessibilityIdentifier(AccessibilityID.installOnlyButton)
                    }
                }
                Spacer()
            }
            secondaryActions(scheme)
            if let message = app.uninstallMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            DeviceToolResultView(app: app)
            // A disabled button alone does not say why; this line does.
            if let blocker = app.runBlocker, !app.run.isRunning {
                Text(blocker).font(.callout).foregroundStyle(.secondary)
            } else if let hint = app.deviceHint, !app.run.isRunning {
                Label(hint, systemImage: "lock.fill").font(.callout).foregroundStyle(.orange)
            } else if !scheme.isInstallable {
                Text(notInstallableNote(scheme)).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// On rows of their own, so the buttons above keep their full titles in a narrow window.
    @ViewBuilder
    private func secondaryActions(_ scheme: Scheme) -> some View {
        if scheme.isInstallable {
            HStack(spacing: Layout.spacing) {
                Toggle("Launch after install", isOn: $app.launchesAfterInstall)
                    .disabled(app.run.isRunning)
                    .accessibilityIdentifier(AccessibilityID.launchToggle)
                if !app.extraDeviceCandidates.isEmpty {
                    Text("Also on").foregroundStyle(.secondary)
                    ExtraDevicesMenu(app: app).disabled(app.run.isRunning)
                }
                Spacer()
                if app.canTestSelection { testButton }
                InstalledAppMenu(app: app, scheme: scheme)
            }
            LaunchOptionsView(app: app)
        } else if app.canTestSelection {
            testButton
        }
    }

    private var testButton: some View {
        Button("Run Tests", systemImage: "checkmark.diamond") { app.runTests() }
            .disabled(app.runBlocker != nil)
            .help("Build this scheme for testing and run its tests on the selected device")
            .accessibilityIdentifier(AccessibilityID.testButton)
    }

    private func notInstallableNote(_ scheme: Scheme) -> String {
        switch scheme.kind {
        case .appExtension: "An extension ships inside its app. Install the app's scheme to get it on a device."
        case .framework: "A framework has nothing to install; Build checks that it compiles."
        case .tests: "This scheme has no app to install. Run Tests builds it and runs its tests."
        case .app, .other: "This scheme has no app to install; Build checks that it compiles."
        }
    }

    /// Rarely needed, so it starts closed.
    @ViewBuilder
    private func targets(_ scheme: Scheme) -> some View {
        let rows = scheme.buildTargets.map { ($0, false) } + scheme.testTargets.map { ($0, true) }
        if !rows.isEmpty {
            DisclosureGroup("\(rows.count) target\(rows.count == 1 ? "" : "s") in this scheme") {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Divider() }
                        HStack {
                            Text(row.0.name)
                            Spacer()
                            Text(row.1 ? "Tests" : kindLabel(for: row.0)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, Layout.spacing)
                        .padding(.vertical, Layout.spacingSmall)
                    }
                }
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
                .padding(.top, Layout.spacingSmall)
            }
            .foregroundStyle(.secondary)
        }
    }

    /// The project file knows a target's exact product type; the scheme only its file name.
    private func kindLabel(for target: SchemeTarget) -> String {
        (project.snapshot?.targets.first { $0.name == target.name }?.kind ?? target.kind).label
    }
}

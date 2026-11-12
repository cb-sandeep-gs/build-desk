import BuildDeskCore
import SwiftUI

/// The selected scheme: where it goes, what it builds, and the controls to build and install it.
struct SchemeDetailView: View {
    @Bindable var app: AppModel
    @Bindable var project: ProjectModel

    var body: some View {
        if let scheme = project.selectedScheme {
            ScrollView {
                VStack(alignment: .leading, spacing: Layout.spacingLarge) {
                    if app.isXcodeOpen { xcodeWarning }
                    header(scheme)
                    destination(scheme)
                    actions(scheme)
                    RunProgressView(run: app.run)
                    if app.run.phase == .succeeded { NewWarningsView(newWarnings: app.newWarnings) }
                    ConsoleView(console: app.console)
                    targets(scheme)
                    HistoryView(records: app.historyForSelectedScheme)
                    BuildFolderView(app: app)
                }
                .frame(maxWidth: Layout.detailMaxWidth, alignment: .leading)
                .padding(Layout.spacingLarge)
                .frame(maxWidth: .infinity, alignment: .leading)
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

    private func header(_ scheme: Scheme) -> some View {
        VStack(alignment: .leading, spacing: Layout.spacingSmall) {
            titleRow(scheme)
            if let record = app.lastInstall { LastInstallLine(record: record) }
        }
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

    private func destination(_ scheme: Scheme) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Layout.spacing, verticalSpacing: Layout.spacing) {
            GridRow {
                Text("Device").foregroundStyle(.secondary).frame(width: Layout.pickerLabelWidth, alignment: .leading)
                devicePicker
            }
            GridRow {
                Text("Configuration").foregroundStyle(.secondary).frame(width: Layout.pickerLabelWidth, alignment: .leading)
                Picker("Configuration", selection: $project.selectedConfiguration) {
                    ForEach(project.snapshot?.configurations ?? [], id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier(AccessibilityID.configurationPicker)
            }
            if !app.extraDeviceCandidates.isEmpty {
                GridRow {
                    Text("Also install on").foregroundStyle(.secondary).frame(width: Layout.pickerLabelWidth, alignment: .leading)
                    ExtraDevicesMenu(app: app)
                }
            }
        }
        .disabled(app.run.isRunning)
    }

    @ViewBuilder private var devicePicker: some View {
        let devices = app.devicesForSelectedScheme
        if devices.isEmpty {
            // Loading, failed and "nothing connected" each say what is going on.
            switch app.devices.state {
            case .idle, .loading:
                HStack(spacing: Layout.spacingSmall) {
                    ProgressView().controlSize(.small)
                    Text("Looking for devices…").foregroundStyle(.secondary)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            case .loaded:
                Text("No device or simulator fits this scheme. Connect a device with a cable and unlock it.")
                    .foregroundStyle(.secondary)
            }
        } else {
            Picker("Device", selection: deviceSelection) {
                deviceSection("Devices", devices.filter { $0.kind == .physical })
                deviceSection("Simulators", devices.filter { $0.kind == .simulator })
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier(AccessibilityID.devicePicker)
        }
    }

    @ViewBuilder
    private func deviceSection(_ title: String, _ devices: [Device]) -> some View {
        if !devices.isEmpty {
            Section(title) {
                ForEach(devices) { device in
                    Label("\(device.name) — \(device.detail)", systemImage: device.symbol).tag(Optional(device.id))
                }
            }
        }
    }

    /// Shows the device that will be used, which is the first ready one until the user picks.
    private var deviceSelection: Binding<String?> {
        Binding(
            get: { app.selectedDevice?.id },
            set: { app.devices.selectedDeviceID = $0 }
        )
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
            // On a row of their own, so the buttons above keep their full titles in a narrow window.
            if scheme.isInstallable {
                HStack(spacing: Layout.spacing) {
                    Toggle("Launch after install", isOn: $app.launchesAfterInstall)
                        .disabled(app.run.isRunning)
                        .accessibilityIdentifier(AccessibilityID.launchToggle)
                    Spacer()
                    InstalledAppMenu(app: app, scheme: scheme)
                }
                LaunchOptionsView(app: app)
            }
            if let message = app.uninstallMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
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

    private func notInstallableNote(_ scheme: Scheme) -> String {
        switch scheme.kind {
        case .appExtension: "An extension ships inside its app. Install the app's scheme to get it on a device."
        case .framework: "A framework has nothing to install; Build checks that it compiles."
        case .tests: "Build Desk builds this scheme but does not run tests yet."
        case .app, .other: "This scheme has no app to install; Build checks that it compiles."
        }
    }

    @ViewBuilder
    private func targets(_ scheme: Scheme) -> some View {
        if !scheme.buildTargets.isEmpty || !scheme.testTargets.isEmpty {
            VStack(alignment: .leading, spacing: Layout.spacingSmall) {
                Text("Targets in this scheme").font(.headline)
                VStack(spacing: 0) {
                    let rows = scheme.buildTargets.map { ($0, false) } + scheme.testTargets.map { ($0, true) }
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Divider() }
                        HStack {
                            Text(row.0.name)
                            Spacer()
                            Text(row.1 ? "Tests" : kindLabel(for: row.0))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, Layout.spacing)
                        .padding(.vertical, Layout.spacingSmall)
                    }
                }
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
            }
        }
    }

    /// The project file knows a target's exact product type; the scheme only its file name.
    private func kindLabel(for target: SchemeTarget) -> String {
        (project.snapshot?.targets.first { $0.name == target.name }?.kind ?? target.kind).label
    }
}

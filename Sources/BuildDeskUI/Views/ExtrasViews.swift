import AppKit
import BuildDeskCore
import SwiftUI

/// What an app prints while it runs on the device, with a filter and a stop button.
struct ConsoleView: View {
    @Bindable var console: ConsoleModel

    var body: some View {
        if console.isVisible {
            VStack(alignment: .leading, spacing: Layout.spacingSmall) {
                HStack(spacing: Layout.spacing) {
                    Text("Console").font(.headline)
                    if let title = console.title {
                        Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    TextField("Filter", text: $console.filter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: Layout.consoleFilterWidth)
                    if console.isRunning {
                        Button("Stop", systemImage: "stop.fill") { console.stop() }
                            .help("Stop following the app's output. The app keeps running.")
                    } else {
                        Button("Clear", systemImage: "trash") { console.clear() }
                    }
                }
                .labelStyle(.iconOnly)

                output
                if let failure = console.failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
                }
                Text("Shows what the app prints (print, NSLog). Unified logging (os_log, Logger) is not included.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier(AccessibilityID.console)
        }
    }

    private var output: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy, so thousands of lines cost only what is on screen.
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(console.visibleLines) { line in
                        Text(line.text)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(Layout.spacingSmall)
            }
            .frame(height: Layout.consoleHeight)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
            .overlay {
                if console.visibleLines.isEmpty {
                    Text(console.lines.isEmpty ? "Waiting for the app to print something…" : "No line matches the filter.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            // Follow the newest line, as a terminal does.
            .onChange(of: console.visibleLines.last?.id) { _, last in
                if let last { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }
}

/// How the install went on each device, shown when there is more than one or something failed.
struct DeviceOutcomesView: View {
    let outcomes: [DeviceOutcome]

    var body: some View {
        if outcomes.count > 1 || outcomes.contains(where: { !$0.succeeded }) {
            VStack(alignment: .leading, spacing: Layout.spacingSmall) {
                ForEach(outcomes, id: \.device.id) { outcome in
                    HStack(alignment: .firstTextBaseline, spacing: Layout.spacingSmall) {
                        Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(outcome.succeeded ? .green : .red)
                            .frame(width: Layout.iconColumnWidth)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(outcome.device.name)
                            if let failure = outcome.failure {
                                Text(failure).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Asks which devices a dropped `.app` or `.ipa` should go on, then shows the install.
public struct ArtifactInstallSheet: View {
    @Bindable var app: AppModel
    let artifact: AppArtifact
    @State private var chosen: Set<String> = []

    public init(app: AppModel, artifact: AppArtifact) {
        self.app = app
        self.artifact = artifact
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Layout.spacing) {
            HStack(spacing: Layout.spacing) {
                Image(systemName: "shippingbox.fill").font(.largeTitle).foregroundStyle(.tint).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Install \(artifact.name)\(artifact.version.map { " \($0)" } ?? "")").font(.title3.weight(.semibold))
                    Text(artifact.bundleIdentifier).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(artifact.isSimulatorBuild ? "Simulator build" : "Device build").font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            devices
            Toggle("Launch after install", isOn: $app.launchesAfterInstall).disabled(app.run.isRunning)
            RunProgressView(run: app.run)
            HStack {
                Spacer()
                Button(app.run.phase == .succeeded ? "Done" : "Cancel") {
                    app.run.stop()
                    app.dismissPendingArtifact()
                }
                .keyboardShortcut(.cancelAction)
                Button("Install") { app.installPendingArtifact(on: chosen) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || app.run.isRunning)
            }
        }
        .padding(Layout.spacingLarge)
        .frame(width: Layout.sheetWidth)
        .onAppear {
            // Start with the first device ticked, so one press of Return installs.
            if let first = app.devicesForPendingArtifact.first { chosen = [first.id] }
        }
    }

    @ViewBuilder private var devices: some View {
        let candidates = app.devicesForPendingArtifact
        if candidates.isEmpty {
            Text(artifact.isSimulatorBuild
                ? "No simulator fits this build."
                : "No connected device fits this build. Connect a device with a cable and unlock it.")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: Layout.spacingSmall) {
                Text("Install on").font(.headline)
                ForEach(candidates) { device in
                    Toggle(isOn: Binding(
                        get: { chosen.contains(device.id) },
                        set: { isOn in if isOn { chosen.insert(device.id) } else { chosen.remove(device.id) } }
                    )) {
                        Label("\(device.name) — \(device.detail)", systemImage: device.symbol)
                    }
                    .disabled(app.run.isRunning)
                }
            }
        }
    }
}

/// Arguments, environment variables and a link for the launch, folded away until needed.
struct LaunchOptionsView: View {
    @Bindable var app: AppModel
    @State private var isExpanded = false

    var body: some View {
        let texts = app.launchTextsForSelection
        DisclosureGroup(isExpanded: $isExpanded) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Layout.spacing, verticalSpacing: Layout.spacingSmall) {
                field("Arguments", "-flag value", \.arguments)
                field("Environment", "NAME=value OTHER=value", \.environment)
                field("Open link", "myapp://screen", \.url)
            }
            .padding(.top, Layout.spacingSmall)
            if case .failure(let error) = texts.options() {
                Label(error.message, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red)
            }
        } label: {
            HStack(spacing: Layout.spacingSmall) {
                Text("Launch options")
                // Folded away, a dot says that something is set.
                if !texts.isEmpty {
                    Image(systemName: "circle.fill").font(.system(size: Layout.setMarkerSize)).foregroundStyle(.tint)
                        .accessibilityLabel("set")
                }
            }
        }
        .disabled(app.run.isRunning)
        .accessibilityIdentifier(AccessibilityID.launchOptions)
    }

    private func field(_ title: String, _ prompt: String, _ keyPath: WritableKeyPath<LaunchTexts, String>) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).frame(width: Layout.pickerLabelWidth, alignment: .leading)
            TextField(title, text: Binding(
                get: { app.launchTextsForSelection[keyPath: keyPath] },
                set: { app.launchTextsForSelection[keyPath: keyPath] = $0 }
            ), prompt: Text(prompt))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .font(.body.monospaced())
            .autocorrectionDisabled()
        }
    }
}

/// "On Test iPhone: installed 2 hours ago · main @ 1a2b3c4 · with local changes".
struct LastInstallLine: View {
    let record: InstallRecord

    var body: some View {
        HStack(spacing: Layout.spacingSmall) {
            Image(systemName: "clock.arrow.circlepath")
            Text("On \(record.deviceName): installed \(record.date.formatted(.relative(presentation: .named)))")
            if let source = record.source {
                Text("·")
                Text("\(source.branch) @ \(source.commit)").font(.callout.monospaced())
                if source.hasLocalChanges { Text("· with local changes") }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .help("What Build Desk last installed for this scheme on this device, and the code it was built from")
    }
}

/// Ticks more devices for the same build. They must be the same kind as the main one.
struct ExtraDevicesMenu: View {
    @Bindable var app: AppModel

    var body: some View {
        Menu {
            ForEach(app.extraDeviceCandidates) { device in
                Toggle(isOn: Binding(
                    get: { app.extraDeviceIDs.contains(device.id) },
                    set: { isOn in if isOn { app.extraDeviceIDs.insert(device.id) } else { app.extraDeviceIDs.remove(device.id) } }
                )) {
                    Label("\(device.name) — \(device.detail)", systemImage: device.symbol)
                }
            }
        } label: {
            let names = app.extraDevices.map(\.name)
            Text(names.isEmpty ? "No other device" : names.formatted(.list(type: .and)))
        }
        .fixedSize()
        .accessibilityIdentifier(AccessibilityID.extraDevices)
    }
}

/// Things to do with the app once it is on the device. They need to know which app that is, so
/// they wait for one install from Build Desk.
struct InstalledAppMenu: View {
    let app: AppModel
    let scheme: Scheme
    @State private var confirmsUninstall = false

    var body: some View {
        Menu {
            Button("Open Console", systemImage: "terminal") { app.openConsoleForSelection() }
            Button("Uninstall from Device…", systemImage: "trash", role: .destructive) { confirmsUninstall = true }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .fixedSize()
        .disabled(app.lastInstall == nil || app.run.isRunning)
        .help(app.lastInstall == nil
            ? "Available after Build Desk has installed this scheme on the selected device"
            : "Console and uninstall")
        .accessibilityIdentifier(AccessibilityID.moreMenu)
        // Removing an app also removes its data, so it is never done on one click.
        .confirmationDialog(
            "Remove \(scheme.name) from \(app.selectedDevice?.name ?? "the device")?",
            isPresented: $confirmsUninstall
        ) {
            Button("Uninstall", role: .destructive) { Task { await app.uninstallSelection() } }
        } message: {
            Text("The app and its data on the device are deleted. This can't be undone.")
        }
    }
}

/// The app's settings: the daily build of the pins.
public struct SettingsView: View {
    @Bindable var schedule: ScheduleModel
    let pinCount: Int

    public init(app: AppModel) {
        schedule = app.schedule
        pinCount = app.pins.count
    }

    public var body: some View {
        Form {
            Section {
                Toggle("Build the pins every day", isOn: $schedule.isEnabled)
                    .accessibilityIdentifier(AccessibilityID.scheduleToggle)
                DatePicker("At", selection: $schedule.time, displayedComponents: .hourAndMinute)
                    .disabled(!schedule.isEnabled)
            } footer: {
                VStack(alignment: .leading, spacing: Layout.spacingSmall) {
                    Text("Each pin is built, not installed, so the first build of your day is a quick one. "
                        + "This happens only while Build Desk is open; add it to your Login Items to have it ready each morning.")
                    if pinCount == 0 {
                        Text("Nothing is pinned yet, so there is nothing to build.").foregroundStyle(.orange)
                    }
                    if let lastFired = schedule.lastFired {
                        Text("Last run: \(lastFired.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(width: Layout.settingsWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}

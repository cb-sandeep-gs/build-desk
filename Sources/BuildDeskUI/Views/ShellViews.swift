import BuildDeskCore
import SwiftUI

/// The toolbar's device picker: where a build is installed, from any page of the window.
struct ToolbarDevicePicker: View {
    let app: AppModel

    var body: some View {
        let devices = app.devicesForSelectedScheme
        if devices.isEmpty {
            // Loading, failed and "nothing connected" each say what is going on.
            switch app.devices.state {
            case .idle, .loading:
                Label("Looking for devices…", systemImage: "iphone").labelStyle(.titleAndIcon).foregroundStyle(.secondary)
            case .failed(let message):
                Label("No devices", systemImage: "exclamationmark.triangle").labelStyle(.titleAndIcon).help(message)
            case .loaded:
                Label("No device", systemImage: "iphone.slash").labelStyle(.titleAndIcon).foregroundStyle(.secondary)
                    .help("No device or simulator fits this scheme. Connect a device with a cable and unlock it.")
            }
        } else {
            // A menu with its own label: a toolbar would show a plain picker as an icon without the name.
            Menu {
                Picker("Device", selection: selection) {
                    section("Devices", devices.filter { $0.kind == .physical })
                    section("Simulators", devices.filter { $0.kind == .simulator })
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label(app.selectedDevice?.name ?? "Choose a device", systemImage: app.selectedDevice?.symbol ?? "iphone")
                    .labelStyle(.titleAndIcon)
            }
            .help(app.selectedDevice.map { "\($0.name) — \($0.detail)" } ?? "The device a build is installed on")
            .disabled(app.run.isRunning)
            .accessibilityIdentifier(AccessibilityID.devicePicker)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ devices: [Device]) -> some View {
        if !devices.isEmpty {
            Section(title) {
                ForEach(devices) { device in
                    Label("\(device.name) — \(device.detail)", systemImage: device.symbol).tag(Optional(device.id))
                }
            }
        }
    }

    /// Shows the device that will be used, which is the first ready one until the person picks.
    private var selection: Binding<String?> {
        Binding(get: { app.selectedDevice?.id }, set: { app.devices.selectedDeviceID = $0 })
    }
}

/// The toolbar's configuration picker.
struct ToolbarConfigurationPicker: View {
    @Bindable var project: ProjectModel
    let isBusy: Bool

    var body: some View {
        Menu {
            Picker("Configuration", selection: $project.selectedConfiguration) {
                ForEach(project.snapshot?.configurations ?? [], id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(project.selectedConfiguration)
        }
        .help("The build configuration")
        .disabled(isBusy)
        .accessibilityIdentifier(AccessibilityID.configurationPicker)
    }
}

/// The field in the middle of the toolbar: the work in progress, how the last run ended, or
/// where the release stands. It is the one place to look, whatever page is open.
struct ToolbarStatusView: View {
    let status: ToolbarStatus

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: Layout.spacingSmall) {
                icon
                Text(status.text).lineLimit(1).truncationMode(.middle)
            }
            .font(.callout)
            // A measured bar while a build of known size runs; nothing otherwise, so the field keeps its height.
            ProgressView(value: status.progress ?? 0)
                .progressViewStyle(.linear)
                .controlSize(.mini)
                .opacity(status.progress == nil ? 0 : 1)
        }
        .padding(.horizontal, Layout.spacing)
        .frame(width: Layout.toolbarStatusWidth)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.toolbarStatus)
    }

    @ViewBuilder private var icon: some View {
        switch status.tone {
        case .working: ProgressView().controlSize(.mini)
        case .good: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .bad: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .neutral: Image(systemName: "hammer").foregroundStyle(.secondary)
        }
    }
}

/// Run and Stop in the toolbar: the selected scheme on the selected device.
struct ToolbarRunButton: View {
    let app: AppModel

    var body: some View {
        if app.run.isRunning || app.tests.isRunning {
            Button("Stop", systemImage: "stop.fill") {
                // Stopping the queue stops its running build too.
                if app.queue.isRunning { app.queue.stop() } else { app.run.stop() }
                app.tests.stop()
            }
            .help("Stop")
            .accessibilityIdentifier(AccessibilityID.stopButton)
        } else {
            Button("Run", systemImage: "play.fill") { app.runSelected(.buildAndInstall) }
                .disabled(app.runBlocker != nil)
                .help(app.runBlocker ?? "Build the selected scheme and install it on the selected device")
        }
    }
}

/// A number with a label and a line of context, as a tile. Used for the facts at the top of a page.
struct StatCard<Trailing: View>: View {
    let title: String
    let value: String
    let detail: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Text(value).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle).minimumScaleFactor(0.8)
                Text(detail ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(Layout.spacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
        .accessibilityElement(children: .contain)
    }
}

extension StatCard where Trailing == EmptyView {
    init(title: String, value: String, detail: String?) {
        self.init(title: title, value: value, detail: detail) { EmptyView() }
    }
}

extension View {
    /// Takes the title out of the toolbar where the system can (macOS 15 and later); earlier
    /// systems keep it, which costs room but nothing else.
    @ViewBuilder
    func hidingToolbarTitle() -> some View {
        if #available(macOS 15, *) {
            toolbar(removing: .title)
        } else {
            self
        }
    }
}

/// A section's heading inside a page.
struct SectionTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.headline)
    }
}

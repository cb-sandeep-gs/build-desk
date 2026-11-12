import AppKit
import BuildDeskCore
import SwiftUI

extension RunModel {
    /// One line on what a running run is doing right now.
    var runningText: String {
        if statuses[.build] == .running {
            if isResolvingPackages { return "Resolving packages…" }
            let tasks = "\(taskCount.formatted()) tasks"
            return currentTarget.map { "\(tasks) · building \($0)" } ?? (taskCount == 0 ? "Starting the build…" : tasks)
        }
        let device = job?.deviceSummary ?? "the device"
        if statuses[.launch] == .running { return "Launching on \(device)…" }
        if statuses[.install] == .running { return "Installing on \(device)…" }
        return "Finding the built app…"
    }

    /// One line on how a successful run ended.
    var successText: String {
        guard let job else { return "Done." }
        guard job.installs else { return "\(job.title) built." }
        // Name only the devices that got the app; the rest are listed with their reasons.
        let reached = deviceOutcomes.isEmpty ? job.devices.map(\.name) : deviceOutcomes.filter(\.succeeded).map(\.device.name)
        let devices = reached.formatted(.list(type: .and))
        return job.launches ? "\(job.title) is installed and running on \(devices)." : "\(job.title) is installed on \(devices)."
    }
}

/// The menu bar popover: pinned scheme and device pairs to build and install in one click, and
/// the state of the current run.
public struct MenuBarView: View {
    private let app: AppModel
    private let openMainWindow: () -> Void

    public init(app: AppModel, openMainWindow: @escaping () -> Void) {
        self.app = app
        self.openMainWindow = openMainWindow
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Layout.spacing) {
            status
            Divider()
            pins
            if let error = app.pinError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button("Open Build Desk", action: openMainWindow)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.link)
        }
        .padding(Layout.spacing)
        .frame(width: Layout.menuBarWidth)
        // The window may be closed, so the popover brings the device list up to date itself.
        .task { await app.refreshEnvironment() }
    }

    @ViewBuilder private var status: some View {
        let run = app.run
        switch run.phase {
        case .idle:
            Label("Ready", systemImage: "hammer").foregroundStyle(.secondary)
        case .running:
            VStack(alignment: .leading, spacing: Layout.spacingSmall) {
                HStack {
                    Text(run.job.map { "\($0.title) → \($0.deviceSummary)" } ?? "Building").font(.headline).lineLimit(1)
                    Spacer()
                    Button("Stop", systemImage: "stop.fill") { run.stop() }
                        .labelStyle(.iconOnly)
                        .help("Stop the build")
                        .accessibilityIdentifier(AccessibilityID.stopButton)
                }
                if let progress = run.buildProgress, run.statuses[.build] == .running {
                    ProgressView(value: progress)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(run.runningText).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        case .succeeded:
            Label(run.successText, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .lineLimit(3)
        case .stopped:
            Label("Stopped.", systemImage: "stop.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var pins: some View {
        if app.pins.isEmpty {
            Text("Nothing pinned yet. In the window, choose a scheme and a device, then press Pin to keep them here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: Layout.spacingSmall) {
                ForEach(app.pins) { pin in
                    PinRow(pin: pin, device: app.device(for: pin), isBusy: app.run.isRunning) {
                        Task { await app.run(pin) }
                    } remove: {
                        app.remove(pin)
                    }
                }
            }
            .accessibilityIdentifier(AccessibilityID.menuBarPins)
        }
    }
}

/// One pinned pair with its one-click button.
private struct PinRow: View {
    let pin: PinnedRun
    /// The pin's device as this Mac sees it now; nil when it is not known at all.
    let device: Device?
    let isBusy: Bool
    let run: () -> Void
    let remove: () -> Void

    private var isReady: Bool { device?.isReady == true }

    var body: some View {
        HStack(spacing: Layout.spacingSmall) {
            Image(systemName: device?.symbol ?? "iphone.slash")
                .foregroundStyle(isReady ? .primary : .tertiary)
                .frame(width: Layout.iconColumnWidth)
            VStack(alignment: .leading, spacing: 1) {
                Text(pin.scheme).lineLimit(1).truncationMode(.middle)
                Text("\(pin.configuration) · \(pin.deviceName)\(isReady ? "" : " — \((device?.issue ?? .notConnected).title)")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Build and install \(pin.scheme) on \(pin.deviceName)", systemImage: "play.fill", action: run)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(isBusy)
                .help("Build and install")
        }
        .padding(.horizontal, Layout.spacingSmall)
        .padding(.vertical, Layout.spacingSmall)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
        .contextMenu {
            Button("Remove from Menu Bar", action: remove)
        }
    }
}

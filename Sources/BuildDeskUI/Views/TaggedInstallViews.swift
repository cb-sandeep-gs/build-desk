import BuildDeskCore
import SwiftUI

/// The state of a release build that is being built from its tag and installed, or how that ended.
struct TaggedInstallBanner: View {
    let app: AppModel
    let install: TaggedInstall

    var body: some View {
        HStack(alignment: .top, spacing: Layout.spacing) {
            content
            Spacer()
            trailing
        }
        .padding(Layout.spacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
        .accessibilityIdentifier(AccessibilityID.taggedInstall)
    }

    /// "27.05.03 → Test iPhone"
    private var title: String { "\(install.build.version) → \(install.deviceName)" }

    @ViewBuilder private var content: some View {
        switch install.phase {
        case .preparing:
            Label {
                Text("Getting the code of \(install.build.id) ready…")
            } icon: {
                ProgressView().controlSize(.small)
            }
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled)
        case .running:
            runState
        }
    }

    @ViewBuilder private var runState: some View {
        let run = app.run
        switch run.phase {
        case .idle, .running:
            VStack(alignment: .leading, spacing: Layout.spacingSmall) {
                Text(title).font(.headline)
                if let progress = run.buildProgress, run.statuses[.build] == .running {
                    ProgressView(value: progress)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text("\(install.scheme) · \(install.configuration) · \(run.runningText)")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        case .succeeded:
            Label("From \(install.build.id): \(run.successText)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Label("\(install.build.id): \(message)", systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(4)
        case .stopped:
            Label("Stopped.", systemImage: "stop.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var trailing: some View {
        if install.phase == .running, app.run.isRunning {
            Button("Stop", systemImage: "stop.fill") { app.run.stop() }
                .labelStyle(.iconOnly)
                .help("Stop the build")
        } else if install.phase != .preparing {
            HStack(spacing: Layout.spacingSmall) {
                // The log, the errors and the warnings are in Build mode, where every run shows them.
                if install.phase == .running { Button("Show Details") { app.mode = .build } }
                Button("Dismiss", systemImage: "xmark") { app.dismissTaggedInstall() }.labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
        }
    }
}

/// How much disk the tagged code and its build output take, with a way to free it.
struct TaggedSourceLine: View {
    let app: AppModel
    @State private var isConfirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.spacingSmall) {
            if let bytes = app.taggedBytes {
                HStack(spacing: Layout.spacingSmall) {
                    Image(systemName: "internaldrive").foregroundStyle(.secondary)
                    Text("Files for tagged builds on this Mac: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                        .foregroundStyle(.secondary)
                    Button("Remove…") { isConfirming = true }
                        .buttonStyle(.link)
                        .disabled(app.run.isRunning || app.taggedInstall?.phase == .preparing)
                }
                .confirmationDialog("Remove the files for tagged builds?", isPresented: $isConfirming) {
                    Button("Remove", role: .destructive) { Task { await app.removeTaggedSource() } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This deletes Build Desk's own copy of the project's code and what was built from it. "
                        + "Your checkout and its build folder are not touched. The next tagged build will be a full one.")
                }
            }
            if let message = app.taggedSourceMessage {
                Text(message).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

import BuildDeskCore
import SwiftUI

/// Chooses a release action, shows what it would do, and runs it only after a confirmation.
public struct ReleaseActionSheet: View {
    @Bindable var model: ReleaseActionModel
    let close: () -> Void

    public init(model: ReleaseActionModel, close: @escaping () -> Void) {
        self.model = model
        self.close = close
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Layout.spacing) {
            Text(model.title).font(.title3.weight(.semibold))
            if case .done(let result) = model.runState {
                done(result)
            } else {
                inputs
                Divider()
                planArea
            }
            footer
        }
        .padding(Layout.spacingLarge)
        .frame(width: Layout.releaseSheetWidth)
        .accessibilityIdentifier(AccessibilityID.releaseSheet)
    }

    // MARK: - Inputs

    @ViewBuilder private var inputs: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Layout.spacing, verticalSpacing: Layout.spacing) {
            switch model.action.kind {
            case .testflight:
                GridRow {
                    label("Track")
                    Picker("Track", selection: $model.action.track) {
                        ForEach(model.app.tracks) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                GridRow {
                    label("Branch")
                    Picker("Branch", selection: $model.action.branch) {
                        Text(model.checkoutBranch.map { "This checkout (\($0))" } ?? "This checkout").tag(String?.none)
                        if !model.branches.isEmpty { Divider() }
                        ForEach(model.branches, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    .labelsHidden().fixedSize()
                }
                if model.needsWrittenNotes {
                    GridRow {
                        label("Notes")
                        TextEditor(text: Binding(get: { model.action.notes ?? "" }, set: { model.action.notes = $0 }))
                            .font(.body)
                            .frame(height: Layout.notesEditorHeight)
                            .overlay(RoundedRectangle(cornerRadius: Layout.cornerRadius).stroke(.quaternary))
                    }
                }
            case .store:
                GridRow {
                    label("Shipped build")
                    Picker("Shipped build", selection: $model.action.from) {
                        ForEach(model.shippedCandidates) { Text($0.version).tag(Optional($0.id)) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
        .disabled(model.runState == .running)
        if let problem = model.problem {
            Text(problem).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(width: Layout.pickerLabelWidth, alignment: .leading)
    }

    // MARK: - Plan

    @ViewBuilder private var planArea: some View {
        switch model.plan {
        case .idle:
            Text("Preview shows what will happen. Nothing is changed until you confirm it.")
                .font(.callout).foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: Layout.spacingSmall) {
                ProgressView().controlSize(.small)
                // A provider may look at the remote to find the next build number.
                Text("Asking the project what would happen. This can take a few seconds.").font(.callout).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
        case .loaded(let plan):
            PlanView(plan: plan)
        }
        if case .failed(let message) = model.runState {
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled)
        }
    }

    private func done(_ result: ReleaseResult) -> some View {
        VStack(alignment: .leading, spacing: Layout.spacingSmall) {
            Label(result.result, systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
            ForEach(result.done, id: \.self) { step in
                Label(step, systemImage: "checkmark").font(.callout)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if model.runState == .running {
                ProgressView().controlSize(.small)
                Text("Working…").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isDone {
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel", action: close).keyboardShortcut(.cancelAction).disabled(model.runState == .running)
                if let plan = model.plan.value {
                    // The button names what it will create, so the last click is never a blind one.
                    Button("Confirm: \(plan.title)") { Task { await model.confirm() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canConfirm)
                        .accessibilityIdentifier(AccessibilityID.releaseConfirm)
                } else {
                    Button("Preview") { Task { await model.preview() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.problem != nil || model.plan == .loading)
                }
            }
        }
    }
}

/// What will happen, in order, with warnings and the notes the build will carry.
private struct PlanView: View {
    let plan: ReleasePlan

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.spacingSmall) {
            Text("What will happen").font(.headline)
            ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: Layout.spacingSmall) {
                    Text("\(index + 1).").foregroundStyle(.secondary).monospacedDigit()
                    Text(step).textSelection(.enabled)
                }
            }
            ForEach(plan.warnings ?? [], id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            }
            if let notes = plan.notes, !notes.isEmpty {
                Text("Notes").font(.headline).padding(.top, Layout.spacingSmall)
                ScrollView {
                    Text(notes).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Layout.spacingSmall)
                }
                .frame(height: Layout.planNotesHeight)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
            }
        }
    }
}

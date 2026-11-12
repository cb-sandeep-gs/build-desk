import AppKit
import BuildDeskUI
import SwiftUI

/// The app's scenes; everything else lives in BuildDeskUI (testable) and BuildDeskCore.
struct BuildDeskApp: App {
    private static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel(environment: .live)

    var body: some Scene {
        Window("Build Desk", id: Self.mainWindowID) {
            BuildDeskRootView(app: model)
        }
        .defaultSize(width: Layout.windowDefaultWidth, height: Layout.windowDefaultHeight)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Project…") { ProjectPicker.chooseAndOpen(in: model) }
                    .keyboardShortcut("o")
                Button("Close Project") { model.closeProject() }
                    .disabled(model.project == nil || model.run.isRunning)
            }
            // The same keys as Xcode, so the habit carries over.
            CommandMenu("Build") {
                Button("Build and Install") { model.runSelected(installs: true) }
                    .keyboardShortcut("r")
                    .disabled(model.runBlocker != nil)
                Button("Build Only") { model.runSelected(installs: false) }
                    .keyboardShortcut("b")
                    .disabled(model.runBlocker != nil)
                Button("Stop") { model.run.stop() }
                    .keyboardShortcut(".")
                    .disabled(!model.run.isRunning)
                Divider()
                Button("Reload Schemes and Devices") {
                    Task {
                        await model.project?.load()
                        await model.refreshEnvironment()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

/// Makes the app a regular foreground app even when launched as a bare SwiftPM executable (`swift run`).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Until the menu bar item exists (BD-3), a closed window means the app is done.
        true
    }
}

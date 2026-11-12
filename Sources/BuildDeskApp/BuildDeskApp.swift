import AppKit
import BuildDeskUI
import SwiftUI

/// The app's scenes; everything else lives in BuildDeskUI (testable) and BuildDeskCore.
struct BuildDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel(environment: .live)

    var body: some Scene {
        Window("Build Desk", id: WindowID.main) {
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
                Button("Build and Install") { model.runSelected(.buildAndInstall) }
                    .keyboardShortcut("r")
                    .disabled(model.runBlocker != nil)
                Button("Build Only") { model.runSelected(.buildOnly) }
                    .keyboardShortcut("b")
                    .disabled(model.runBlocker != nil)
                Button("Install Last Build") { model.runSelected(.installOnly) }
                    .keyboardShortcut("i")
                    .disabled(model.runBlocker != nil)
                Button("Run Tests") { model.runTests() }
                    .keyboardShortcut("u")
                    .disabled(model.runBlocker != nil || !model.canTestSelection)
                Button("Stop") {
                    model.run.stop()
                    model.tests.stop()
                }
                .keyboardShortcut(".")
                .disabled(!model.run.isRunning && !model.tests.isRunning)
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

        // The hammer fills while a build is running, so progress is visible from any app.
        MenuBarExtra {
            MenuBarContent(app: model)
        } label: {
            Label("Build Desk", systemImage: model.run.isRunning ? "hammer.fill" : "hammer")
        }
        .menuBarExtraStyle(.window)
    }
}

/// The popover, with the way back to the main window (only a view can open a window).
private struct MenuBarContent: View {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarView(app: app) {
            openWindow(id: WindowID.main)
            NSApp.activate(ignoringOtherApps: true)
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
        // The menu bar item keeps working with the window closed; Quit is in its popover and the app menu.
        false
    }
}

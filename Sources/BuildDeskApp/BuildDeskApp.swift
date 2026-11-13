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
                // The daily build starts counting as soon as the app is up.
                .task { model.schedule.restart() }
                // Release builds are watched from the start too, for the menu bar and notifications.
                .task { model.releaseWatch.activate() }
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
                    // Stopping the queue stops its running build too.
                    if model.queue.isRunning { model.queue.stop() } else { model.run.stop() }
                    model.tests.stop()
                }
                .keyboardShortcut(".")
                .disabled(!model.run.isRunning && !model.tests.isRunning)
                Button("Run All Pins") { model.queue.start(model.pins, mode: .buildAndInstall) }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(model.pins.isEmpty || model.queue.isRunning || model.run.isRunning || model.tests.isRunning)
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

        Settings {
            SettingsView(app: model)
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

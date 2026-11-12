import AppKit
import BuildDeskUI
import SwiftUI

/// Renders the window to a PNG without showing it: `BuildDeskApp --snapshot out.png`.
///
/// Used to check the layout at a given size and appearance from a script, and to make README
/// screenshots. It shows the made-up demo project unless `--project` names a real one.
@MainActor
enum Snapshot {
    enum Argument {
        static let snapshot = "--snapshot"
        static let project = "--project"
        static let width = "--width"
        static let height = "--height"
        static let dark = "--dark"
        static let welcome = "--welcome"
        static let menu = "--menu"
        static let installed = "--installed"
        static let sheet = "--sheet"
        static let tested = "--tested"
        static let settings = "--settings"
        static let icon = "--icon"
        static let release = "--release"
    }

    /// Time for SwiftUI to lay out and for the first loads to finish before the picture is taken.
    private static let settleTime: Duration = .milliseconds(1200)
    /// Far outside any screen, so the window is never seen.
    private static let offscreenOrigin = CGPoint(x: -20_000, y: -20_000)

    static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// What the picture shows: the welcome screen, a real project, or one of the demo scenes.
    private static func makeModel(_ arguments: [String]) async -> AppModel {
        if arguments.contains(Argument.welcome) {
            return AppModel(environment: .live, store: Demo.scratchStore())
        } else if let project = value(after: Argument.project, in: arguments) {
            let model = AppModel(environment: .live, store: Demo.scratchStore())
            await model.open(URL(fileURLWithPath: project))
            await model.refreshEnvironment()
            // A real project's Release mode, read through its own release commands.
            if arguments.contains(Argument.release), model.release != nil {
                model.mode = .release
                await model.release?.refresh()
            }
            return model
        } else if arguments.contains(Argument.sheet) {
            return await Demo.app(showing: .appFile)
        } else {
            let scene: Demo.Scene = arguments.contains(Argument.installed) ? .installed
                : arguments.contains(Argument.tested) ? .tested
                : arguments.contains(Argument.release) ? .release : .building
            return await Demo.app(showing: scene)
        }
    }

    /// Writes the app icon as a PNG at its full size: `BuildDeskApp --icon out.png`.
    static func renderIcon(arguments: [String]) -> Int32 {
        guard let output = value(after: Argument.icon, in: arguments) else { return EXIT_FAILURE }
        let renderer = ImageRenderer(content: AppIconView())
        // One pixel per point, so the file is exactly the canvas size whatever the screen is.
        renderer.scale = 1
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return EXIT_FAILURE }
        do {
            try png.write(to: URL(fileURLWithPath: output))
            return EXIT_SUCCESS
        } catch {
            FileHandle.standardError.write(Data("Couldn't write \(output): \(error.localizedDescription)\n".utf8))
            return EXIT_FAILURE
        }
    }

    static func run(arguments: [String]) async -> Int32 {
        guard let output = value(after: Argument.snapshot, in: arguments) else { return EXIT_FAILURE }
        let size = CGSize(
            width: value(after: Argument.width, in: arguments).flatMap(Double.init) ?? Layout.windowDefaultWidth,
            height: value(after: Argument.height, in: arguments).flatMap(Double.init) ?? Layout.windowDefaultHeight
        )
        NSApplication.shared.setActivationPolicy(.accessory)

        let model = await makeModel(arguments)

        // The menu bar popover and the app-file sheet are drawn in a bare window as tall as their
        // content; the main window in a titled one of the requested size.
        let content: NSView
        if arguments.contains(Argument.settings) {
            content = NSHostingView(rootView: SettingsView(app: model).background(.background))
        } else if arguments.contains(Argument.menu) {
            content = NSHostingView(rootView: MenuBarView(app: model) {}.background(.background))
        } else if arguments.contains(Argument.sheet), let artifact = model.pendingArtifact {
            content = NSHostingView(rootView: ArtifactInstallSheet(app: model, artifact: artifact).background(.background))
        } else {
            content = NSHostingView(rootView: BuildDeskRootView(app: model, autoloads: false))
        }
        let isMenu = !(content is NSHostingView<BuildDeskRootView>)
        let frame = CGRect(origin: offscreenOrigin, size: isMenu ? content.fittingSize : size)
        let window = NSWindow(
            contentRect: frame,
            styleMask: isMenu ? [.borderless] : [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: arguments.contains(Argument.dark) ? .darkAqua : .aqua)
        window.contentView = content
        window.setFrame(frame, display: true)
        window.orderFront(nil)
        try? await Task.sleep(for: settleTime)

        // The frame view is the whole window, title bar and toolbar included.
        guard let view = isMenu ? content : window.contentView?.superview,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return EXIT_FAILURE }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return EXIT_FAILURE }
        do {
            try png.write(to: URL(fileURLWithPath: output))
        } catch {
            FileHandle.standardError.write(Data("Couldn't write \(output): \(error.localizedDescription)\n".utf8))
            return EXIT_FAILURE
        }
        return EXIT_SUCCESS
    }
}

import BuildDeskCore
import SwiftUI

/// Sizes and spacing used across the window.
public enum Layout {
    public static let windowDefaultWidth: CGFloat = 1180
    public static let windowDefaultHeight: CGFloat = 720
    public static let windowMinWidth: CGFloat = 920
    public static let windowMinHeight: CGFloat = 480

    static let sidebarMinWidth: CGFloat = 210
    static let sidebarIdealWidth: CGFloat = 250
    static let sidebarMaxWidth: CGFloat = 360
    /// The detail column stops growing here, so lines stay readable on a wide window.
    static let detailMaxWidth: CGFloat = 980
    static let toolbarStatusWidth: CGFloat = 300
    static let inspectorWidth: CGFloat = 290
    /// Lines of a build's notes shown before Show All.
    static let inspectorNotesLines = 6
    static let tableVersionWidth: CGFloat = 78
    static let tableTrackWidth: CGFloat = 150
    static let tableTrackMinWidth: CGFloat = 70
    /// The builds table never gets narrower than this; the window's minimum width follows from it.
    static let releaseTableMinWidth: CGFloat = 400
    static let welcomeWidth: CGFloat = 420
    public static let menuBarWidth: CGFloat = 330
    public static let sheetWidth: CGFloat = 460
    public static let settingsWidth: CGFloat = 440
    static let consoleHeight: CGFloat = 220
    static let consoleFilterWidth: CGFloat = 160
    static let trendHeight: CGFloat = 64
    static let setMarkerSize: CGFloat = 6
    public static let releaseSheetWidth: CGFloat = 520
    static let notesEditorHeight: CGFloat = 90
    static let planNotesHeight: CGFloat = 150
    /// Characters of a commit shown to people.
    static let shortCommitLength = 7
    /// Builds shown in the build-time trend, and runs listed under it.
    static let trendRunCount = 30
    static let historyRowCount = 6
    static let activityRowCount = 40

    static let spacingSmall: CGFloat = 6
    static let spacing: CGFloat = 12
    static let spacingLarge: CGFloat = 20
    static let cornerRadius: CGFloat = 8
    static let iconColumnWidth: CGFloat = 18
    static let pickerLabelWidth: CGFloat = 96
    static let heroIconSize: CGFloat = 56
    /// Warnings shown before the list asks to be expanded; a large project has hundreds.
    static let diagnosticsShownAtOnce = 50
}

/// Names of the app's windows, shared by the scenes and the views that open them.
public enum WindowID {
    public static let main = "main"
}

/// Identifiers for UI tests and accessibility tools.
public enum AccessibilityID {
    public static let openProject = "open-project"
    public static let schemeList = "scheme-list"
    public static let devicePicker = "device-picker"
    public static let configurationPicker = "configuration-picker"
    public static let runButton = "run-button"
    public static let buildOnlyButton = "build-only-button"
    public static let installOnlyButton = "install-only-button"
    public static let pinButton = "pin-button"
    public static let menuBarPins = "menu-bar-pins"
    public static let console = "console"
    public static let moreMenu = "more-menu"
    public static let extraDevices = "extra-devices"
    public static let newWarnings = "new-warnings"
    public static let launchOptions = "launch-options"
    public static let testButton = "test-button"
    public static let testResults = "test-results"
    public static let runAllButton = "run-all-button"
    public static let releaseView = "release-view"
    public static let releaseSheet = "release-sheet"
    public static let newTestBuild = "new-test-build"
    public static let releaseConfirm = "release-confirm"
    public static let scheduleToggle = "schedule-toggle"
    public static let releaseWatchToggle = "release-watch-toggle"
    public static let menuBarReleases = "menu-bar-releases"
    public static let taggedInstall = "tagged-install"
    public static let toolbarStatus = "toolbar-status"
    public static let releaseInspector = "release-inspector"
    public static let downloadArtifact = "download-artifact"
    public static let releaseChecks = "release-checks"
    public static let releaseTable = "release-table"
    public static let activityView = "activity-view"
    public static let taggedInstallButton = "tagged-install-button"
    public static let history = "history"
    public static let cleanButton = "clean-button"
    public static let stopButton = "stop-button"
    public static let launchToggle = "launch-toggle"
    public static let runStatus = "run-status"
}

extension SchemeKind {
    var label: String {
        switch self {
        case .app: "App"
        case .appExtension: "Extension"
        case .framework: "Framework"
        case .tests: "Tests"
        case .other: "Scheme"
        }
    }

    var symbol: String {
        switch self {
        case .app: "app.badge"
        case .appExtension: "puzzlepiece.extension"
        case .framework: "shippingbox"
        case .tests: "checkmark.diamond"
        case .other: "square.dashed"
        }
    }
}

extension ProductKind {
    var label: String {
        switch self {
        case .application: "Application"
        case .watchApplication: "Watch app"
        case .appExtension: "App extension"
        case .framework: "Framework"
        case .library: "Library"
        case .unitTests: "Tests"
        case .uiTests: "UI tests"
        case .other: "Other"
        }
    }
}

extension Platform {
    var symbol: String {
        switch self {
        case .iOS: "iphone"
        case .watchOS: "applewatch"
        case .tvOS: "appletv"
        case .visionOS: "visionpro"
        case .macOS: "macbook"
        }
    }
}

extension Device {
    /// "iOS 27.2 · wired", "iOS 27.2 · simulator" or "iOS 27.2 · not connected".
    var detail: String {
        let state = switch (kind, isReady, connection) {
        case (.simulator, _, _): isBooted ? "simulator, booted" : "simulator"
        case (.physical, false, _): issue?.title ?? "not ready"
        case (.physical, true, .wired): "wired"
        case (.physical, true, _): "Wi-Fi"
        }
        return "\(platform) \(osVersion) · \(state)"
    }

    var symbol: String { platformKind?.symbol ?? "iphone" }
}

/// Short durations for people: "8 s", "3 m 20 s".
public enum DurationText {
    private static let secondsPerMinute = 60

    public static func short(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        guard total >= secondsPerMinute else { return "\(total) s" }
        return "\(total / secondsPerMinute) m \(total % secondsPerMinute) s"
    }
}

/// A small rounded label, used for a scheme's kind and platform.
struct Badge: View {
    let text: String
    var symbol: String?

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let symbol { Image(systemName: symbol) }
        }
        .labelStyle(.titleAndIcon)
        .font(.caption)
        .padding(.horizontal, Layout.spacingSmall + 2)
        .padding(.vertical, 2)
        .background(.quaternary, in: Capsule())
    }
}

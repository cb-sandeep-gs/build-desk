import Foundation

/// Every tool path, file name and limit Build Desk uses, in one place.
public enum BuildDeskConstants {
    /// The version of the app and the command-line tool. `Scripts/build-app.sh` reads it from here.
    public static let version = "0.15.0"

    /// Absolute paths of the Apple tools Build Desk drives. `xcrun` finds `devicectl` and `simctl`
    /// inside the selected Xcode.
    public enum ToolPath {
        public static let xcodebuild = "/usr/bin/xcodebuild"
        public static let xcrun = "/usr/bin/xcrun"
        public static let unzip = "/usr/bin/unzip"
        public static let git = "/usr/bin/git"
        public static let diskUsage = "/usr/bin/du"
    }

    /// File and folder names inside an Xcode project or workspace.
    public enum ProjectLayout {
        public static let projectExtension = "xcodeproj"
        public static let workspaceExtension = "xcworkspace"
        public static let projectFile = "project.pbxproj"
        public static let workspaceFile = "contents.xcworkspacedata"
        public static let sharedSchemesPath = "xcshareddata/xcschemes"
        public static let userDataFolder = "xcuserdata"
        public static let userSchemesFolder = "xcschemes"
        public static let schemeExtension = "xcscheme"
    }

    /// Where full run logs are kept and how many are kept.
    public enum Logs {
        public static let folderName = "BuildDesk"
        public static let fileExtension = "log"
        /// Older run logs beyond this count are deleted when a new run starts.
        public static let keptRuns = 20
        /// Lines of a failed tool's output carried in the error shown to the user.
        public static let failureTailLines = 12
    }

    /// The configuration used when the caller does not pick one and the project names no default.
    public static let fallbackConfiguration = "Debug"

    /// How long to wait for the last output after a streamed tool exits. A child process the tool
    /// left behind can keep the pipe open, so the end of output is not guaranteed to arrive.
    public static let outputDrainGrace: TimeInterval = 1
}

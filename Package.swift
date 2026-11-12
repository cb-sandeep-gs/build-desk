// swift-tools-version: 6.0
// Build Desk — build, install and launch any Xcode scheme on a device without opening Xcode.
// Layout: BuildDeskCore (all logic, no UI) · builddesk (CLI). The app targets arrive in BD-2.

import PackageDescription

let package = Package(
    name: "BuildDesk",
    platforms: [
        // macOS 14: SwiftUI Table, MenuBarExtra and the Observation framework (used from BD-2).
        .macOS(.v14),
    ],
    products: [
        .library(name: "BuildDeskCore", targets: ["BuildDeskCore"]),
        .executable(name: "builddesk", targets: ["builddesk"]),
    ],
    targets: [
        .target(name: "BuildDeskCore"),
        .executableTarget(name: "builddesk", dependencies: ["BuildDeskCore"]),
        .testTarget(name: "BuildDeskCoreTests", dependencies: ["BuildDeskCore"]),
    ],
    swiftLanguageModes: [.v6]
)

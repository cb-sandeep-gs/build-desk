// swift-tools-version: 6.0
// Build Desk — build, install and launch any Xcode scheme on a device without opening Xcode.
// Layout: BuildDeskCore (all logic, no UI) · builddesk (CLI).
// BuildDeskUI (view models + SwiftUI views, testable) · BuildDeskApp (the macOS app entry point only).

import PackageDescription

let package = Package(
    name: "BuildDesk",
    platforms: [
        // macOS 14: the Observation framework, ContentUnavailableView and MenuBarExtra.
        .macOS(.v14),
    ],
    products: [
        .library(name: "BuildDeskCore", targets: ["BuildDeskCore"]),
        .library(name: "BuildDeskUI", targets: ["BuildDeskUI"]),
        .executable(name: "builddesk", targets: ["builddesk"]),
        .executable(name: "BuildDeskApp", targets: ["BuildDeskApp"]),
    ],
    targets: [
        .target(name: "BuildDeskCore"),
        .executableTarget(name: "builddesk", dependencies: ["BuildDeskCore"]),
        .target(name: "BuildDeskUI", dependencies: ["BuildDeskCore"]),
        .executableTarget(name: "BuildDeskApp", dependencies: ["BuildDeskUI"]),
        .testTarget(name: "BuildDeskCoreTests", dependencies: ["BuildDeskCore"]),
        .testTarget(name: "BuildDeskUITests", dependencies: ["BuildDeskUI", "BuildDeskCore"]),
    ],
    swiftLanguageModes: [.v6]
)

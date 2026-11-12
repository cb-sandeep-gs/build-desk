# Build Desk — plan

A small Mac app that builds any scheme of an Xcode project, installs it on a connected device and launches it,
without opening Xcode. Xcode must be installed (Build Desk drives `xcodebuild`, `devicectl` and `simctl`), but it
never needs to be running.

## What the app shows

- **Schemes**, grouped by what can be done with them: apps (build, install, launch), extensions (shown under the
  app they ship in), frameworks (build only), tests (build only at first).
- **Targets** of the selected scheme with their product type.
- **Devices**: wired, Wi-Fi and simulators, refreshed while the window is open.
- **Configuration** picker, read from the project (not hardcoded to Debug and Release).
- **Progress**: Resolve → Build → Sign → Install → Launch, with errors and warnings as `file:line`.
- **Menu bar popover** with pinned scheme and device pairs for one-click installs.

## Architecture

Nothing project-specific in code. A project's own preferences (pinned schemes, hidden schemes, default
configuration) live in a `.builddesk.json` file at that project's repo root.

| Layer | Holds |
|---|---|
| `BuildDeskCore` | All logic: project reading, device discovery, build runner, install and launch, output parsing. |
| `builddesk` CLI | Thin layer over the core; the same operations from a terminal or a script. |
| `BuildDeskUI` / `BuildDeskApp` | View models and SwiftUI views; no logic of their own. |

Every tool call goes through one client type with an argv list (never a shell string) and parses machine-readable
output (`-json`, `--json-output`) only.

## Phases

| Phase | Result | Status |
|---|---|---|
| BD-0 Proof | `Scripts/phase0-proof.sh` builds, installs and launches a scheme on a real device with Xcode closed. | Done 2026-11-12 |
| BD-1 Core | Swift package: scheme and target list, device list, build runner with parsed progress, tests. | Done 2026-11-12 |
| BD-2 Main window | Scheme list, targets, device and configuration pickers, build and install, live progress. | Done 2026-11-12 |
| BD-3 Menu bar | Popover with pinned pairs, finish notification, "install last build" without rebuilding. | Not started |
| BD-4 Extras | Several devices at once, drag in an `.ipa` or `.app`, device console, uninstall, commit shown per install. | Not started |

## What BD-1 built

`BuildDeskCore` (no UI, no dependencies) and the `builddesk` command-line tool.

| Part | Types | What it does |
|---|---|---|
| Tools | `ToolRunning`, `ProcessToolRunner`, `AppleTools` | The one doorway to `xcodebuild`, `devicectl` and `simctl`: argv lists only, output collected or streamed line by line, cancellation stops the tool. |
| Project | `ProjectReader`, `ProjectSnapshot`, `Scheme`, `ProjectTarget` | `quickSnapshot` reads scheme files and `project.pbxproj` with no tool run; `fullSnapshot` adds schemes only `xcodebuild -list` knows. |
| Devices | `DeviceDiscovery`, `Device` | Real devices from `devicectl`, simulators from `simctl`, usable ones first. |
| Build | `BuildPipeline`, `BuildOutputParser`, `RunLog` | Build → locate → install → launch as a stream of events, with errors and warnings parsed and de-duplicated, and the full output kept in a rotated log file. |

Checked on the Mercury iOS project (19 scheme files, 16 targets): the scheme list appears in 0.5 s where
`xcodebuild -list` took 32 s. A full `builddesk run` on a wired iPhone, from a clean build folder, took 240 s
(build 225 s, locate 6 s, install 10 s, launch under 1 s) and reported 9,842 build tasks and 657 distinct warnings.

## What BD-2 built

`BuildDeskUI` (view models and SwiftUI views) and `BuildDeskApp` (the app entry point), bundled by
`Scripts/build-app.sh`.

| Part | Types | What it does |
|---|---|---|
| App state | `AppModel`, `PreferenceStore` | Opens a project, workspace or the folder that holds one; remembers recent projects, the last scheme, configuration and device. |
| Scheme list | `ProjectModel`, `SchemeListView` | Schemes grouped as Apps, Extensions, Frameworks, Tests; filter field; package schemes loaded on request because that listing is slow. |
| Scheme detail | `SchemeDetailView` | Device and configuration pickers, targets, Build and Install, Build Only, Stop, Launch after install; says why a run cannot start. |
| Run | `RunModel`, `RunProgressView` | Step strip, elapsed time, progress measured against the last build of the same scheme, errors and warnings with `file:line`, link to the full log. |
| Devices | `DeviceListModel` | Refreshed every 5 s while the window is open; only devices whose platform fits the scheme are offered. |
| Checks | `Snapshot`, `Demo` | `BuildDeskApp --snapshot out.png` renders the window off screen at any size, light or dark, with a made-up demo project or a real one. |

Core additions: each target's platform (from `SDKROOT`), `ProjectLocator` (finds the project inside a chosen
folder), service protocols (`ProjectReading`, `DeviceDiscovering`, `BuildRunning`) so view models are tested with
fakes, and extension schemes that also build their app count as installable.

Menu keys match Xcode: ⌘R build and install, ⌘B build only, ⌘. stop, ⇧⌘R reload, ⌘O open.

Known gaps:

- **Not clicked through by hand yet.** The window was checked from rendered snapshots (demo and the Mercury
  project) and the run path is tested with fakes; the same pipeline ran on a real device from the command line.
  A person still needs to press Build and Install in the window once.
- **Simulator install and launch** are covered by tests against a fake tool runner, not yet tried on a real simulator.
- **A test scheme that also has a Run action** (it runs the host app) is listed under Apps.
- **Workspace groups:** project references nested in workspace groups with their own paths are not followed.
- **Progress on the first build of a scheme** is a busy bar; the measured bar needs one earlier build to compare with.

## Findings from BD-0

Facts measured on the Mercury iOS project that shape BD-1:

- `xcodebuild -list -json` took 32 s (it resolves Swift packages first). The app must not wait on it to draw the
  scheme list: read the `.xcscheme` files directly and cache, and use `xcodebuild -list` only to confirm.
- The project has four configurations (Debug, Production Debug, Release, Distribution), so the picker is data-driven.
- `devicectl list devices --json-output` gives name, UDID, model, OS, transport (`wired` or network), pairing and
  tunnel state per device; the same UDID works as the `xcodebuild -destination id=`.
- A scheme builds several targets; the product to install is the one whose `PRODUCT_TYPE` is
  `com.apple.product-type.application`, found with `-showBuildSettings -json`.
- Full run on a wired iPhone 17 (iOS 27.2), Xcode closed: build 184 s, locate 6 s, install 7 s, launch 1 s.
  Automatic signing worked from the command line with `-allowProvisioningUpdates` for the app, its widget,
  notification extension and watch app. The device build folder was 4.5 GB.
- The build log had 1,280 warning lines and was 14 MB, so the app needs a parsed, filtered log view and must
  rotate old logs.

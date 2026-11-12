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
| BD-1 Core | Swift package: scheme and target list, device list, build runner with parsed progress, tests. | Not started |
| BD-2 Main window | Scheme list, targets, device and configuration pickers, build and install, live log. | Not started |
| BD-3 Menu bar | Popover with pinned pairs, finish notification, "install last build" without rebuilding. | Not started |
| BD-4 Extras | Several devices at once, drag in an `.ipa` or `.app`, device console, uninstall, commit shown per install. | Not started |

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

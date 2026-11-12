# Build Desk

Build any scheme of an Xcode project, install it on a connected iPhone or iPad and launch it, without opening
Xcode.

Build Desk drives the command-line tools that ship inside Xcode (`xcodebuild`, `devicectl`, `simctl`), so Xcode
must be installed but never needs to be running. Signing uses the Apple account already saved in Xcode.

**Status:** the Mac app's main window works (BD-2), on top of the core library and the `builddesk` command-line
tool (BD-1). The menu bar item comes in BD-3. See [docs/PLAN.md](docs/PLAN.md).

## Use the app

Requirements: macOS 14 or later with Xcode installed, a device that has been paired with this Mac once, and Xcode
closed while a build runs.

```bash
./Scripts/build-app.sh
```

```bash
open .build/BuildDesk.app
```

1. Choose **Open Project…** and pick a `.xcodeproj`, a `.xcworkspace`, or the folder that contains one (a
   repository checkout works). You can also drop it on the window.
2. Pick a scheme in the list. Schemes are grouped as Apps, Extensions, Frameworks and Tests.
3. Pick a device and a configuration. Only devices that fit the scheme's platform are offered.
4. Press **Build and Install** (⌘R). **Build Only** (⌘B) compiles without installing; **Stop** (⌘.) ends a run.

The app is ad-hoc signed for local use. The first time you open a copy built on another Mac, macOS asks you to
confirm it in System Settings.

## Use the command-line tool

```bash
swift build -c release
```

The tool is then at `.build/release/builddesk`.

| Command | What it does |
|---|---|
| `builddesk schemes <project>` | Lists schemes with their kind (app, appExtension, framework, tests) and products. Reads project files only, so it returns at once. |
| `builddesk schemes <project> --full` | Also asks `xcodebuild` for schemes that have no scheme file, such as Swift package schemes. Slower. |
| `builddesk targets <project>` | Lists targets with their product kind. |
| `builddesk devices` | Lists real devices and simulators, usable ones first. |
| `builddesk run <project> --scheme <name> --device <name-or-udid>` | Builds the scheme, installs the app on the device and launches it. |

`<project>` is a `.xcodeproj` or `.xcworkspace`. Add `--json` to `schemes`, `targets` and `devices` for
machine-readable output.

Options of `run`:

| Option | Meaning |
|---|---|
| `--configuration <name>` | Build configuration. Defaults to the project's own default. |
| `--no-launch` | Install the app but don't open it. |
| `--build-only` | Build and stop; for frameworks and compile checks. |

The build goes into Xcode's normal DerivedData folder, so it is incremental with builds made from Xcode itself.
The full output of each run is kept in `~/Library/Logs/BuildDesk` (the newest 20 runs).

## Develop

```bash
swift build && swift test && swiftlint lint --strict
```

All logic is in `Sources/BuildDeskCore`. The command-line tool (`Sources/builddesk`) and the app
(`Sources/BuildDeskUI` for view models and views, `Sources/BuildDeskApp` for the entry point) are thin layers over
it. Tests use fakes and made-up fixtures, so they need no Xcode project and no device. Working rules are in
[CLAUDE.md](CLAUDE.md).

To check the window without opening it, render it to an image:

```bash
.build/debug/BuildDeskApp --snapshot window.png
```

This shows a made-up demo project with a build in progress. Add `--dark`, `--width <points>`, `--height <points>`,
`--welcome` for the welcome screen, or `--project <path>` for a real project.

## The phase 0 proof script

The shell script that first proved the flow is kept for reference; `builddesk run` replaces it.

```bash
# Schemes, targets and configurations of a project (JSON)
./Scripts/phase0-proof.sh schemes /path/to/App.xcodeproj

# Connected and known devices (JSON), including each device's UDID
./Scripts/phase0-proof.sh devices

# Build, install and launch
./Scripts/phase0-proof.sh run /path/to/App.xcodeproj <scheme> <device-udid> [configuration]
```

`configuration` defaults to `Debug`. Set `BUILDDESK_NO_LAUNCH=1` to stop after the install.

# Build Desk

Build any scheme of an Xcode project, install it on a connected iPhone or iPad and launch it, without opening
Xcode.

Build Desk drives the command-line tools that ship inside Xcode (`xcodebuild`, `devicectl`, `simctl`), so Xcode
must be installed but never needs to be running. Signing uses the Apple account already saved in Xcode.

**Status:** all planned phases are built: the core library and `builddesk` command-line tool (BD-1), the main
window (BD-2), the menu bar item (BD-3), the extras (BD-4), what a team needs to share it (BD-5: project
settings file, device checks, release script), build insight (BD-6), launch options (BD-7), running tests (BD-8), a build queue with a daily build (BD-9) and device tools (BD-10). What is built is in [docs/PLAN.md](docs/PLAN.md); what comes next
is in [docs/ROADMAP.md](docs/ROADMAP.md).

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
4. Press **Build and Install** (⌘R). **Build Only** (⌘B) compiles without installing; **Install Last Build** (⌘I)
   puts the app from the last build on the device without rebuilding; **Stop** (⌘.) ends a run.

**Several devices.** With more than one device of the same kind connected, **Also install on** ticks the others;
one build is installed on all of them and each device's result is listed.

**App files.** Drop a built `.app` or `.ipa` on the window to install it without a project. A sheet shows what the
app is and offers the devices it fits.

**After an install.** Under the scheme name the window shows when it was last installed on the selected device and
the branch and commit it was built from. The **More** menu opens the app's **console** (what it prints with
`print` and `NSLog`; unified logging is not included) and can **uninstall** it, after a confirmation.

**Device tools.** Also in **More**: **Take Screenshot** saves a picture of the device's screen to the Desktop;
**Download App Data** copies the installed app's data folder to a folder you choose; **Save Crash Logs** copies
the app's newest crash reports. Each one ends with a Show in Finder link.

**Launch options.** Under the buttons, **Launch options** takes command-line arguments, environment variables
(`NAME=value`, separated by spaces) and a link to open, for example to start the app with a debug flag or on a
particular screen. Each scheme remembers its own, and a pin keeps the options it was made with.

**Tests.** **Run Tests** (⌘U) appears on any scheme that has tests. It builds the scheme for testing, runs the
tests on the selected device or simulator and lists the failures first, each with its reason and `file:line`.
**Re-run Failed** runs only what failed; right-click a test or a class to run just that.

**History.** Each scheme lists its past runs with how long they took, their warnings and the branch and commit
they were built from, above a build-time trend. After a build, the window names the warnings that no earlier
build of that scheme had.

**Build folder.** The bottom of the window shows how much disk the project's build output takes. **Clean…**
deletes it after a confirmation; the next build is then a full one.

**Menu bar.** Press **Pin** in the window to keep the current scheme, configuration and device in the menu bar.
The hammer icon there opens a list of your pins, each with a one-click build and install, plus the progress of
the current run. The app keeps running when its window is closed; quit it from the popover or with ⌘Q.

**Run all pins.** With two or more pins, **Run All** in the popover builds and installs them one after another
and sends one notification at the end. A pin that fails does not stop the others.

**Daily build.** In Settings (⌘,), **Build the pins every day** builds each pin at a set time, without
installing, so your first build of the day is quick. It runs only while Build Desk is open.

**Notifications.** When a run ends while you are in another app, Build Desk posts a notification with the result.
macOS asks for permission the first time.

The app is ad-hoc signed for local use. The first time you open a copy built on another Mac, macOS asks you to
confirm it in System Settings.

**When a device can't be used**, the window says which of these it is and what to do: not connected, not
trusted by this Mac, Developer Mode off. A locked device is flagged too; the app can be installed on it but not
opened until it is unlocked.

## Project settings for a team

Put a `.builddesk.json` file beside the Xcode project, or anywhere above it up to the repository root, and check
it in. Everyone who opens the project in Build Desk then gets the same setup. Every key is optional.

```json
{
  "favoriteSchemes": ["App", "App Staging"],
  "hiddenSchemes": ["*Tests", "Pods-*"],
  "defaultScheme": "App",
  "defaultConfiguration": "Debug"
}
```

| Key | Type | Meaning |
|---|---|---|
| `release` | object | The project's release commands, which give it a Release mode. See [docs/release-contract.md](docs/release-contract.md). |
| `favoriteSchemes` | list of names | Listed first, in this order, in a Favorites group. |
| `hiddenSchemes` | list of names | Left out of the list. A name must match in full; `*` stands for any run of characters. A "Show hidden" box in the sidebar brings them back. |
| `defaultScheme` | name | Selected the first time a person opens the project. After that their own last choice is used. |
| `defaultConfiguration` | name | The same, for the build configuration. |

A file that can't be read, or that has a key Build Desk doesn't know, never stops the project from opening: the
sidebar shows what is wrong. The format is described in [docs/builddesk.schema.json](docs/builddesk.schema.json).

## Share the app with other Macs

macOS only opens a downloaded app without complaint when it is signed with a Developer ID and notarized by Apple.

```bash
./Scripts/release.sh
```

This builds, signs, notarizes and zips the app into `dist/BuildDesk-<version>.zip`, and prints the command that
publishes it as a GitHub release. It needs one-time setup on the Mac that makes releases; the steps are at the top
of [Scripts/release.sh](Scripts/release.sh). The script never asks for or stores a password.

Until a Developer ID is set up, `./Scripts/release.sh --adhoc` makes a zip that teammates can still use by
clearing its quarantine flag once (the script prints the command), or they can build from source with
`./Scripts/build-app.sh`.

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
| `builddesk install <app-or-ipa> --device <name-or-udid>` | Installs a built `.app` or `.ipa` and launches it. |
| `builddesk console <bundle-id> --device <name-or-udid>` | Relaunches an installed app and prints what it writes until it exits or you press Ctrl-C. |
| `builddesk uninstall <bundle-id> --device <name-or-udid>` | Removes an app and its data from the device. |
| `builddesk screenshot --device <name-or-udid> --output <file.png>` | Saves a picture of the device's screen. |
| `builddesk appdata <bundle-id> --device <name-or-udid> --output <folder>` | Copies an installed app's data folder. |
| `builddesk crashes <process-name> --device <name-or-udid>` | Lists the app's crash logs, newest first; `--output <folder>` copies them. |
| `builddesk release status <project>` | Where each app stands: version, store release and the latest build per track, from the project's own release commands. |
| `builddesk release plan <project> --action testflight\|store --app <id>` | What a release action would do, with its notes. Changes nothing. |
| `builddesk test <project> --scheme <name> --device <name-or-udid>` | Runs the scheme's tests and prints the failures. `--only <Bundle[/Class[/test]]>` limits the run. Exits with 2 when tests failed. |

`<project>` is a `.xcodeproj` or `.xcworkspace`. Add `--json` to `schemes`, `targets` and `devices` for
machine-readable output.

Options of `run`:

| Option | Meaning |
|---|---|
| `--configuration <name>` | Build configuration. Defaults to the project's own default. |
| `--no-launch` | Install the app but don't open it. |
| `--build-only` | Build and stop; for frameworks and compile checks. |
| `--install-only` | Install the app the last build left behind, without rebuilding. |
| `--also <name-or-udid>` | A second device of the same kind to install the same build on (also for `install`). |
| `--launch-args "<args>"` | Command-line arguments for the app (also for `install` and `console`). |
| `--launch-env "<N=v N=v>"` | Environment variables for the app (also for `install` and `console`). |
| `--launch-url <link>` | A link the app opens at launch (also for `install` and `console`). |

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

Every pull request, and every push to `main` or `develop`, runs the same checks on GitHub
(`.github/workflows/ci.yml`).

The app icon is drawn in code (`AppIconView`). After changing it, run `./Scripts/make-icon.sh` and commit the
new `Resources/AppIcon.icns`.

To check the window without opening it, render it to an image:

```bash
.build/debug/BuildDeskApp --snapshot window.png
```

This shows a made-up demo project with a build in progress. Add `--dark`, `--width <points>`, `--height <points>`,
`--welcome` for the welcome screen, `--menu` for the menu bar popover, `--installed` for the state after an install
(last-install line and console), `--sheet` for the app-file sheet, or `--project <path>` for a real project.

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

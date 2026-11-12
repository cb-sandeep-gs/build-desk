# Build Desk — plan

A small Mac app that builds any scheme of an Xcode project, installs it on a connected device and launches it,
without opening Xcode. Xcode must be installed (Build Desk drives `xcodebuild`, `devicectl` and `simctl`), but it
never needs to be running.

What comes next (remaining work, next phases, larger directions) is in [ROADMAP.md](ROADMAP.md).

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
| BD-3 Menu bar | Popover with pinned pairs, finish notification, "install last build" without rebuilding. | Done 2026-11-13 |
| BD-10 Device tools | Screenshot, app data folder and crash logs from a device or simulator. Unified logs are still open. | Done 2026-11-13 |
| BD-11 Distribution (part) | App icon and checks on every push. Auto-update is still open. | Done 2026-11-13 |
| BD-9 Build queue | Run every pin one after another with one notification; build the pins once a day. | Done 2026-11-13 |
| BD-8 Run tests | Run a scheme's tests, or one class or test, with results per test and a re-run of the failed ones. | Done 2026-11-13 |
| BD-7 Launch options | Arguments, environment variables and a link for the launch, per scheme and per pin. | Done 2026-11-13 |
| BD-6 Build insight | Run history, new-warning diff, build-time trend, build folder size with Clean. | Done 2026-11-13 |
| BD-5 Team-ready | Project settings file, device checks with a fix for each problem, release script (Developer ID, notarization), known gaps closed. | Done 2026-11-13 |
| BD-4 Extras | Several devices at once, drag in an `.ipa` or `.app`, device console, uninstall, commit shown per install. | Done 2026-11-13 |

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

## What BD-3 built

| Part | Types | What it does |
|---|---|---|
| Pins | `PinnedRun`, `AppModel.run(_:)` | The Pin button in the window saves the scheme, configuration and device together. Running a pin opens its project if needed, selects everything and builds and installs. |
| Menu bar | `MenuBarView` | A hammer in the menu bar (filled while building) opens a popover with the current run, its progress and Stop, the pins with a one-click button each, Open Build Desk and Quit. |
| Notification | `RunNotice`, `UserNotificationNotifier` | When a run ends while Build Desk is not the front app, a system notification says what was installed where and how long it took, or why it failed. A stopped run says nothing. Permission is asked the first time there is something to say. |
| Install last build | `BuildRequest.builds`, `RunMode.installOnly` | Skips the build and installs the app the last build left behind; says so plainly when there is none. Also `builddesk run --install-only` and ⌘I. |

The app now keeps running when its window is closed, so the menu bar item stays available.

## What BD-4 built

| Part | Types | What it does |
|---|---|---|
| Several devices | `BuildRequest.additionalDevices`, `DeviceOutcome` | "Also install on" ticks more devices of the same kind; one build goes on all of them. A device that fails does not stop the others, and each device's result is listed. |
| App files | `ArtifactReader`, `InstallRequest`, `ArtifactInstallSheet` | Drop a `.app` or `.ipa` on the window (or choose it in Open): a sheet shows what it is and offers only devices it fits (device build or simulator build). No project is needed. |
| Console | `DeviceAppService.console`, `ConsoleModel`, `ConsoleView` | More ▸ Open Console relaunches the installed app attached to its output: the newest 2,000 lines, with a filter. It shows what the app prints (`print`, `NSLog`), not unified logging. |
| Uninstall | `DeviceAppService.uninstall` | More ▸ Uninstall from Device asks for confirmation, then removes the app and its data. |
| Last install | `InstallRecord`, `SourceStateReader` | Under the scheme name: when it was last installed on the selected device, and the branch and commit it was built from, with a note when tracked files had local changes. |

The command line gained `install`, `uninstall`, `console` and `run --also`. Stopping the tool (Ctrl-C or `kill`)
now stops whatever it was running, so no build or console session is left behind.

Tried on a wired iPhone with the real tools: build and install (217 s), install last build (9 s), install the
built `.app` as a file (4 s), and the console (about 1,000 lines in 20 s, and nothing left running after a stop).

## What BD-10 built

| Part | Types | What it does |
|---|---|---|
| Screenshot | `DeviceToolsService.screenshot` | More ▸ Take Screenshot saves a picture of the selected device's screen to the Desktop, named after the device and the time. Needs only a ready device, not an install. |
| App data | `DeviceToolsService.copyAppData` | More ▸ Download App Data copies the installed app's data folder (Documents, Library, tmp) into a new folder you choose. On a device this is one `devicectl` copy; on a simulator the files are already on the Mac. |
| Crash logs | `DeviceToolsService.crashLogs`, `CrashLog` | More ▸ Save Crash Logs copies the newest 20 crash reports of the scheme's app, matched by the name the app runs under. It says so plainly when there are none. |

Each tool reports what it saved with a Show in Finder link, or why it failed. The command line has
`builddesk screenshot`, `appdata` and `crashes`.

Tried on a wired iPhone with the real tools: a screenshot, the full data folder of an installed app (46 MB) and
a crash log listing and copy. The app had no crash reports of its own, so the copy was checked on a system
report. Everything fetched was deleted afterwards.

Still open in BD-10: unified logging (`os_log`, `Logger`) in the console (see ROADMAP.md).

## What BD-11 built so far

| Part | Files | What it does |
|---|---|---|
| App icon | `AppIconView`, `Scripts/make-icon.sh`, `Resources/AppIcon.icns` | The icon is drawn in code. The script renders it (`BuildDeskApp --icon`) and builds the `.icns`, which is checked in, so building the app needs no extra step. `Scripts/build-app.sh` puts it in the bundle. |
| Checks on push | `.github/workflows/ci.yml` | On every pull request and on pushes to `main` and `develop`: lint, script syntax, build, tests, a command-line smoke test and a check that the app bundle holds only its binary, icon and Info.plist. Written to match the sibling tool's workflow; it has not run yet, because it runs only once pushed. |

Still open in BD-11: checking for a newer release and offering to install it (see ROADMAP.md).

## What BD-9 built

| Part | Types | What it does |
|---|---|---|
| Queue | `QueueModel` | Run All in the menu bar popover (and ⌥⌘R) builds and installs every pin in order. A pin that fails, or whose device is away, does not stop the ones after it. Each pin shows its result, and one notification sums up the queue in place of one per build. Stop All stops the running build and skips the rest. |
| Daily build | `ScheduleModel`, `SettingsView` | Settings (⌘,) has "Build the pins every day" with a time. At that time each pin is built, not installed, so the first build of the day is a quick one. It runs only while Build Desk is open, and is skipped when something is already running. No system setting is changed. |

## What BD-8 built

| Part | Types | What it does |
|---|---|---|
| Runner | `TestRunner`, `TestRequest`, `TestEvent` | Runs `xcodebuild test` for a scheme on a device or simulator, optionally limited with `-only-testing`. Progress comes from the live output; the results come from the result bundle, which is read once with `xcresulttool` and then deleted. |
| Results | `TestResultsParser`, `TestCaseResult`, `TestRunSummary` | Every test with its bundle, class, status, time and each failure's message and `file:line`. An expected failure counts as passed. |
| Window | `TestRunModel`, `TestResultsView` | Run Tests (⌘U) on any scheme that has tests. While running: tests finished so far and the latest one. After: passed, failed and skipped counts, the failures first with their reasons, then every class. Re-run Failed runs only what failed; a right-click runs one test or one class. |
| Notification | `RunNotice.make(for: TestRunModel)` | When tests end while Build Desk is in the background. |

Tried with the real tools: one test class of a large app on a temporary simulator (5 tests passed, 289 s
including the build for testing); the result bundle was read and deleted. That run showed `xcodebuild` prints a
finished test in a second shape when tests run in parallel on simulator clones; the live parser reads both.

`xcodebuild` exits with a failure both when the build breaks and when a test fails; the two are told apart by
whether the result bundle holds any test. The command line has `builddesk test`, which exits with 2 when tests
ran and some failed.

## What BD-7 built

| Part | Types | What it does |
|---|---|---|
| Options | `LaunchOptions`, `LaunchTexts` | Command-line arguments, environment variables (`NAME=value`) and a link to open, typed in three fields under Launch options. Text is split as a shell splits it, so quotes keep a value with spaces together. A mistake is explained under the fields and blocks the run. |
| Per scheme and per pin | `AppModel.launchTextsForSelection`, `PinnedRun.launchOptions` | Each scheme remembers its own options. A pin keeps the options it was made with, so one scheme can be pinned twice: plain, and with a debug flag. |
| Launch | `AppleTools.launchOnDevice`, `launchOnSimulator`, `openURLOnSimulator` | On a device everything goes in one `devicectl` launch. On a simulator the variables travel through the tool's environment and the link is opened right after the launch. The console starts the app the same way. |

The command line takes the same options: `--launch-args`, `--launch-env` and `--launch-url` on `run`, `install`
and `console`. Tried on a wired iPhone: the installed app was relaunched with an argument and a variable.

## What BD-6 built

| Part | Types | What it does |
|---|---|---|
| Run history | `RunRecord`, `FileRunHistoryStore` | Every run from the app is recorded: scheme, configuration, device, what was done, result, time per build and in total, tasks, warnings, errors, branch and commit. Kept in `~/Library/Application Support/BuildDesk/history.json`, newest 500. Shown per scheme under History. |
| New-warning diff | `WarningDiff`, `Diagnostic.fingerprint` | After a build, the warnings no earlier build of that scheme and configuration had, with `file:line`. A warning is identified by its file and message, not its line, so it stays "known" when code above it moves. |
| Build-time trend | `HistoryView` | One bar per successful build, so a build that starts taking longer stands out. |
| Build folder | `BuildFolderService`, `BuildFolderView` | Finds the project's folder in Xcode's DerivedData (by the project path Xcode records in it), shows the size of its build output, and deletes that output behind a confirmation. Refused while Xcode is open or a build runs. Packages and the index are kept. |

How "new" is decided: the set of known warnings only grows. An incremental build prints warnings only for the
files it recompiled, so a warning missing from one build has not necessarily been fixed. The cost is that a
warning which is fixed and later comes back is not flagged as new.

## What BD-5 built

| Part | Types | What it does |
|---|---|---|
| Project settings | `ProjectConfig`, `ProjectConfigLoader` | `.builddesk.json` beside the project or above it up to the repository root: favorite schemes, hidden schemes (with `*`), default scheme and configuration. A broken file is reported in the sidebar and never stops a project from opening. Schema in `docs/builddesk.schema.json`. |
| Device checks | `DeviceIssue`, `DeviceDiscovery.isLocked` | Each device that can't be used says why (not connected, not trusted, Developer Mode off) with the fix. A locked device is a hint, not a blocker, because the install still works. |
| Release | `Scripts/release.sh` | Developer ID signing with the hardened runtime, notarization, stapling and a zip in `dist/`; `--adhoc` for a zip without a Developer ID. |
| Closed gaps | — | A scheme named after its test target is listed under Tests. Projects inside workspace groups are found. Simulator versions read correctly for model-specific runtimes. |

Tried on a temporary simulator with the real tools: build, install and launch (259 s), the console, install
last build (19 s) and uninstall. The simulator was deleted afterwards.

Known gaps:

- **Not clicked through by hand yet.** The window and the menu bar popover were checked from rendered snapshots
  and the run path is tested with fakes; the same pipeline ran on a real device from the command line. A person
  still needs to press Build and Install, run a pin and see a notification once.
- **Several devices at once** and **`.ipa` files** are covered by tests against fakes; only one device was
  connected and no `.ipa` was at hand.
- **Uninstall on a real device** was not run, to keep the data of the app on the test device; it was run for real
  on a simulator. The tool reports success when asked to remove an app that is not installed, so Build Desk does too.
- **A signed release has not been made.** `Scripts/release.sh` was run in `--adhoc` mode only; the Mac it was
  written on has no Developer ID certificate. The signing and notarization steps are untried.
- **Device checks for "not trusted" and "Developer Mode off"** are covered by tests on made-up tool output; no
  device in that state was at hand. The lock check was read from a real, unlocked device.
- **An iOS version newer than the installed Xcode supports** is not detected; the build fails with Xcode's own message.
- **Console is standard output only.** Unified logging (`os_log`, `Logger`) needs a different tool and is not shown.
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

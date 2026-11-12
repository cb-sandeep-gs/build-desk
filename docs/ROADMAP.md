# Build Desk — roadmap

What is left to finish, what to build next, and where the tool could go. Written 2026-11-13, after phases BD-0 to
BD-5. What is already built is described in [PLAN.md](PLAN.md).

## Where it stands

Build Desk builds any scheme of an Xcode project, installs it on real devices and simulators and launches it, with
Xcode closed. It has a main window, a menu bar item with one-click pins, a command-line tool, a project settings
file for teams and a release script. The core has 121 tests.

| Area | State |
|---|---|
| Build, install, launch on a real device | Works; tried on a wired iPhone. |
| Build, install, launch, console, uninstall on a simulator | Works; tried on a temporary simulator. |
| Install last build, install a `.app` file, console on a device | Works; tried on a wired iPhone. |
| Main window and menu bar popover | Built and checked from rendered images; not yet used by hand. |
| Signed, notarized release | Script written; not run, because no Developer ID certificate was available. |

## 1. Remaining things

Work that finishes what exists. None of it is new functionality.

### Needs a person

| Item | Why it is open | Who |
|---|---|---|
| Use the app by hand once | Every screen was checked from images and tests, never by clicking. Press Build and Install, run a pin from the menu bar, see a notification arrive, drop an app file on the window. | Any developer |
| Make the first signed release | Needs the team's "Developer ID Application" certificate and notarization credentials saved with `xcrun notarytool store-credentials`. Then run `./Scripts/release.sh` and publish the zip as a GitHub release. | Whoever holds the certificate |
| Move the repository to the organisation | It is under a personal account today; a team tool should be where the team already has access. | Repository owner |
| Check in the project's `.builddesk.json` | The settings file for the first project that uses Build Desk exists but is not committed there. | That project's owner |

### Not yet tried on real hardware

These paths are covered by tests against fakes only.

| Path | What is needed to try it |
|---|---|
| Install on several devices at once | Two devices of the same kind connected. |
| Install an `.ipa` file | An exported `.ipa`. |
| Uninstall from a real device | A device whose app data may be deleted. |
| "Not trusted" and "Developer Mode off" messages | A device in that state, for example a newly reset one. |
| Wi-Fi devices | A device paired for network use, with the cable removed. |

### Known limits

| Limit | Effect | Possible fix |
|---|---|---|
| Console shows standard output only | `os_log` and `Logger` output is missing. | Needs research; see section 4. |
| First build of a scheme has no measured progress | A busy bar until one build has finished. | Estimate from the number of source files, or from another configuration's count. |
| An iOS version newer than Xcode supports is not detected | The build fails with Xcode's own message. | Compare the device's version with the installed Xcode's device support. |
| Cleaning the build folder disables Install Last Build | The button reports "no built copy" until the next build. | The disk panel in BD-6 makes this visible and deliberate. |
| No app icon | The app shows the generic icon in the Dock and Finder. | Add an icon set to the bundle script. |
| No checks on push | Tests and lint run only when someone runs them. | A GitHub Actions workflow: `swift build`, `swift test`, `swiftlint lint --strict`. |

## 2. Next phases

Ordered by how much each helps day-to-day work. Sizes are rough: S is a day or two, M about a week, L more.

| Phase | What it adds | Size | Depends on |
|---|---|---|---|
| BD-6 Build insight | History of runs, new-warning diff, build time trend, disk panel | M | — |
| BD-7 Launch options | Launch arguments, environment variables and a deep link per pin | S | — |
| BD-8 Run tests | Run a test scheme or one test class and show results per test | M | — |
| BD-9 Build queue | Several schemes one after another; scheduled builds | M | BD-6 |
| BD-10 Device tools | Screenshot, crash logs, app data folder, unified logs | L | Research |
| BD-11 Distribution | Auto-update, app icon, checks on push | M | First signed release |

### BD-6 Build insight

Things Xcode does not show.

- **Run history:** every run with scheme, device, duration per step, warning count, branch and commit. Kept as a
  small local file per project, with a limit on its size.
- **New-warning diff:** "3 new warnings since the last build" with `file:line`, instead of the same several hundred
  every time. The diagnostics are already parsed and de-duplicated; this needs them stored per run.
- **Build time trend:** duration per scheme over the last runs, so a slow-down is noticed when it starts.
- **Disk panel:** the size of the project's build folder and a Clean button behind a confirmation. Replaces
  cleaning by hand and says plainly that the next build will be a full one.

### BD-7 Launch options

- **Arguments and environment per pin:** for example one pin that launches the app with a debug flag set and
  another without. `devicectl` and `simctl` both accept them at launch.
- **Open a link after launch:** a deep link per pin, to land on the screen being worked on.

### BD-8 Run tests

- Run a test scheme, or a single test class, on a simulator or device.
- Show pass and fail per test with the failure message and `file:line`, read from the result bundle that
  `xcodebuild test` writes (machine-readable, so no log parsing).
- Re-run only the failed tests.

### BD-9 Build queue

- Queue several schemes (for example two apps of one project) and get one notification at the end.
- Scheduled builds: build a pin every morning so the first build of the day is incremental.

### BD-10 Device tools

- Screenshot of the device or simulator, saved or copied.
- Pull crash logs and the app's data folder.
- Unified logging in the console. Needs research first (section 4).

### BD-11 Distribution

- Check for a newer release and offer to install it. Needs a decision on adding a dependency (Sparkle) or writing
  a small updater against GitHub releases.
- App icon.
- Checks on push and a release workflow that runs `Scripts/release.sh` on a tagged commit.

## 3. Potentials

Larger directions. Each would need its own plan before any code.

| Direction | What it would be | Why it could matter |
|---|---|---|
| Archive and export | Archive a scheme, export an `.ipa`, upload to TestFlight | Release builds without Xcode. May overlap with existing release tooling, so decide where it belongs first. |
| Build another branch without switching | Build a branch or commit from a separate worktree | Install a colleague's branch on a device while your own checkout stays as it is. |
| Explain a failed build | Send the errors of a failed build to a language model and show a short diagnosis with the likely fix | Signing and package errors are hard to read; the errors are already extracted. Must be opt-in, since it sends build output off the Mac. |
| Shared build status | A small status page or chat message: who installed which commit on which test device | Useful for QA devices shared by a team. |
| Automation hooks | A URL scheme, Shortcuts actions and a stable JSON output for every command | Lets other tools and scripts start a build or read its result. |
| Android | The same window for Gradle builds and `adb` installs | One tool for both mobile teams. The core is tool-agnostic behind `ToolRunning`; project reading and device discovery would be new. |
| Headless runner | The command-line tool as a nightly build job on a shared Mac, posting results | Catches a broken build before the team starts work. |
| Several projects at once | Tabs or a project switcher, with pins across projects | For people who work in more than one app. |

## 4. Questions to answer before building

| Question | Affects | Notes |
|---|---|---|
| How can unified logging be read from a real device without Xcode? | BD-10 | `devicectl` has no command for it. `log stream` works for simulators (through `simctl spawn`). For devices, options are a private framework or a third-party tool; both have costs. |
| Is one dependency acceptable for auto-update? | BD-11 | The package has no dependencies today. |
| Where should archive and upload live? | Potentials | In Build Desk, or in the tooling that already handles releases. |
| Which chat or status system would shared build status post to? | Potentials | Decides the format and the credentials needed. |
| How long should run history be kept, and is it per person or shared? | BD-6 | Per person is simple and private; shared needs a place to store it. |

## 5. Suggested order

1. Finish section 1 "Needs a person": use the app by hand, make the first signed release, move the repository.
2. BD-6 Build insight: the most useful addition for daily work, and BD-9 builds on it.
3. BD-7 Launch options: small, and makes pins much more useful.
4. BD-8 Run tests.
5. Decide on the questions in section 4, then pick from BD-9 to BD-11 and the potentials.

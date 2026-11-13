# Build Desk — roadmap

What is left to finish, what to build next, and where the tool could go. Written 2026-11-13, after phases BD-0 to
BD-5. BD-6 to BD-10 and part of BD-11 have been built since and are described in PLAN.md. What is already built is described in [PLAN.md](PLAN.md).

## Where it stands

Build Desk builds any scheme of an Xcode project, installs it on real devices and simulators and launches it, with
Xcode closed. It has a main window, a menu bar item with one-click pins, a command-line tool, a project settings
file for teams, a release script, run history with a new-warning diff, a build folder panel, launch options per pin, a test runner, a build queue, a daily build and device tools (screenshot, app data, crash logs). It has 181 tests.

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
| The push checks have not run yet | The workflow is written but only runs once it is pushed; the hosted Mac may have an older Swift than the one used so far. | Push, read the first run, fix what it finds. |

## 2. Next phases

Ordered by how much each helps day-to-day work. Sizes are rough: S is a day or two, M about a week, L more.

| Phase | What it adds | Size | Depends on |
|---|---|---|---|
| BD-10 Device tools (rest) | Unified logs in the console | M | Research |
| BD-11 Distribution (rest) | Check for a newer release and offer to install it; a release workflow on a tagged commit | S | First signed release, and a decision on a dependency |

### BD-10 Device tools (rest)

- Unified logging in the console. For a simulator this is within reach (`simctl spawn <device> log stream` with a
  filter on the app's process). For a real device it needs research first (section 4).
- Screen recording, which `simctl` offers for simulators.

### BD-11 Distribution

- Check for a newer release and offer to install it. Needs a decision on adding a dependency (Sparkle) or writing
  a small updater against GitHub releases.
- A release workflow that runs `Scripts/release.sh` on a tagged commit. It needs the signing certificate and the
  notarization credentials stored as repository secrets.

### Follow-ups to what is built

| Item | What it would add |
|---|---|
| Daily build without the app open | A login item or launch agent, so the daily build does not depend on Build Desk running. It changes a system setting, so it needs a clear switch and the person's consent. |
| Build for "any device" | A scheduled build of a pin whose phone is not connected fails today; a generic destination would let it build anyway. |
| Test history | Test runs are not kept in the run history; pass and fail counts over time would show flaky tests. |
| Queue from the window | The queue is started from the menu bar and the Build menu; the window could show its progress too. |

## 3. Potentials

Larger directions. Each would need its own plan before any code.

| Direction | What it would be | Why it could matter |
|---|---|---|
| Release mode | A second mode beside Build that shows where each app stands and offers the release actions, driven by commands the project supplies | Planned in [RELEASE-INTEGRATION.md](RELEASE-INTEGRATION.md): a release contract in `.builddesk.json`, steps R0 to R4. Built so far: R0 to R2, the reading half of R3, and of R4 the menu bar status, notifications and installing a tagged build. The integration is complete as planned; store writes were verified as plans only. |
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
| Where should archive and upload live? | Potentials | Tags and store status stay with the project and reach Build Desk through the release contract (RELEASE-INTEGRATION.md). Archiving and uploading from this Mac is still undecided. |
| Which chat or status system would shared build status post to? | Potentials | Decides the format and the credentials needed. |
| Should run history be shared by a team? | Shared build status | It is per person today (the newest 500 runs, on that Mac). Sharing needs a place to store it. |

## 5. Suggested order

1. Finish section 1 "Needs a person": use the app by hand, make the first signed release, move the repository.
2. Decide on the questions in section 4, then pick from BD-9 to BD-11 and the potentials.

# Build Desk — working rules

These rules apply to every code change and design decision in this repository.

Plan and phase status: [docs/PLAN.md](docs/PLAN.md). Work one phase (BD-n) at a time; each phase ends with tests
and docs.

## Architecture
- **BuildDeskCore holds all logic.** The CLI and the app (BuildDeskUI view models + views, BuildDeskApp entry
  point) stay thin layers over it, so a new front end (menu bar, CLI command, automation) changes little. View
  models are `@MainActor @Observable`, take their services as protocols, and are tested in BuildDeskUITests.
- **Clear boundaries:** project reading, device discovery, build running and output parsing are separate types
  behind protocols, so each is testable without Xcode or a device.
- **Apple tools only through one client.** argv lists only, never a shell string. Parse machine-readable output
  (`-json`, `--json-output`) only, never human-readable text. The one exception is build progress
  (`BuildOutputParser`): a build has no machine-readable output, so it recognises a few long-standing line shapes
  and treats every other line as not an event.
- **Nothing project-specific in code.** Project differences belong in `.builddesk.json` at that project's root.
  When a config key changes, update the type, its validation, the schema and the README table together.
- **No duplication:** shared logic goes into one helper or type; prefer composition and protocols over copy-paste.
- Swift 6 language mode, strict concurrency. No new dependencies without discussion.

## Constants and configuration
- **No magic numbers or strings.** Tool names, flags, JSON keys, product types, defaults keys, timeouts and sizes
  are named constants in one place.
- **Types over strings:** enums for product types, device states, build steps and configurations read from tools.
- An inline literal is fine only when its meaning is obvious (`0`, `1`, `true`, a loop counter).

## Safety
- **Never change the user's project or checkout.** Build Desk reads projects and runs builds; it writes only its
  own logs and settings.
- **Never pass `-derivedDataPath`.** Builds go to Xcode's own DerivedData so they stay shared and incremental; a
  private copy of a large app costs several GB.
- **No credentials.** Signing uses the account saved in Xcode. Build Desk never asks for, stores or logs Apple ID
  passwords, tokens or signing keys.
- **No personal data in the repo.** Device UDIDs, device names, team IDs, signing identities and local paths stay
  out of code, tests, fixtures, docs and commit messages; use made-up values in fixtures.
- **Destructive actions need the user's click:** uninstalling an app, deleting a build folder or clearing logs
  is never automatic. Never uninstall a real app from a user's device to test; use the error path or a fake.
- **Git is read-only.** Build Desk reads the branch and commit of a checkout and never changes it.

## Performance and memory
- **The main thread only draws.** Process runs, file reads and output parsing happen off it; the window must stay
  responsive during a build that prints tens of thousands of lines.
- **Stream, don't buffer.** Build output is parsed line by line; the UI shows a bounded window of it, and full
  logs go to disk with rotation.
- **No leaks:** no retain cycles in closures or tasks; cancel tasks, stop processes and close pipes when a build
  is stopped or a window closes. A stopped build must leave no `xcodebuild` child process behind.

## UI and UX
- **Every view handles loading, empty, error and partial states**, for example no project open, no device
  connected, device locked, Xcode not installed, build failed.
- **Errors say what happened and what to do next**, never a raw tool dump (the full output stays one click away).
- **Adaptive window:** works from the minimum window size up to full screen, in light and dark mode.
- **Accessibility:** labels on icon-only controls, full keyboard use, Dynamic Type-friendly text, and
  accessibility identifiers on important controls for UI tests.

## Comments
- Comment the why, briefly, on every change. No noise comments.

## Tests
- XCTest. Parsers get tests against captured tool output kept as fixtures (with personal data replaced).
- Core logic is tested with a fake tool client; tests never need Xcode, a device or the network.

## Verify before handing over
```bash
swift build && swift test && swiftlint lint --strict
bash -n Scripts/*.sh        # when a script changed
```
No new warnings. When UI changed, render the window and look at it, at the default and the minimum size, light
and dark:
```bash
.build/debug/BuildDeskApp --snapshot window.png
.build/debug/BuildDeskApp --snapshot small-dark.png --dark --width 760 --height 480
.build/debug/BuildDeskApp --snapshot menu.png --menu        # the menu bar popover
.build/debug/BuildDeskApp --snapshot after.png --installed  # last-install line and console
.build/debug/BuildDeskApp --snapshot sheet.png --sheet      # the app-file sheet
```

## Testing against a real project
- Each device build of a large app is several GB. Measure first (`du -sh`, `df -h`).
- Build for one specific device or simulator, never a generic destination.
- When the task is done (never mid-task), delete build folders created only for the test, unless the user wants
  to keep them, and say how much space was freed. Skip this if Xcode is running.
- Uninstall test apps from simulators booted for the task and shut those simulators down. Leave apps on the
  user's real devices alone.

## App bundle hygiene
- The shipped `.app` contains only the binary and its resources: no docs, markdown, scripts, fixtures or agent
  config.

## Git
- Conventional Commits (`feat(core): …`), with a short bullet body for key changes.
- No `Co-Authored-By:` or any other AI/tool attribution trailer.
- Commit locally per phase; push only when the user asks.
- Every response that changes code ends with the commit message in a code block.

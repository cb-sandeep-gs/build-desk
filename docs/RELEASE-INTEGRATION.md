# Build Desk — release integration plan

How a project's release workflow (tags, TestFlight builds, App Store status) becomes a Release mode in Build Desk.
Written 2026-11-13. Steps R0, R1 and R2 are built, the read-only half of R3, and the menu bar status and notifications of R4; the rest of R3 and R4 are not. The contract itself is described for providers in
[release-contract.md](release-contract.md). Roadmap: [ROADMAP.md](ROADMAP.md).

## The idea

Build Desk gets a second mode beside Build: **Release**. It shows where each app stands (version in code, what is
on the App Store, the latest TestFlight build per track) and offers the release actions, each with a preview and
a confirmation.

Build Desk does not learn how any project releases. The project supplies commands that print JSON in a small
documented shape, the **release contract**, and names them in its `.builddesk.json`. Build Desk draws native UI
from that JSON and runs the project's own commands for every action. A project without a `release` section in
its settings file has no Release mode.

## Why a contract, and not the alternatives

| Option | What it is | Verdict |
|---|---|---|
| Release contract | Build Desk calls commands the project names and draws native UI from their JSON | Chosen |
| Embed a web page | Start the project's own web console and show its release page in a web view | Quick, but not native, needs a server running, and ties Build Desk to one project's console |
| Rewrite in Swift | Tags and the App Store Connect API reimplemented in Build Desk | Rejected: duplicates the project's logic and puts store credentials in Build Desk |

The contract keeps three existing rules: nothing project-specific in Build Desk's code, no credentials in Build
Desk, and Apple tools and project tools only through one client with argv lists and machine-readable output.

## The release contract

Declared in `.builddesk.json`. Each entry is an argv list run from the folder that holds the settings file.

```json
{
  "release": {
    "status": ["./tool", "release", "status", "--json"],
    "plan": ["./tool", "release", "tag", "--plan", "--json"],
    "run": ["./tool", "release", "tag", "--yes", "--json"],
    "checks": ["./tool", "release", "check", "--json"],
    "store": ["./tool", "release", "store-status", "--json"]
  }
}
```

| Command | Asked for | Returns |
|---|---|---|
| `status` | When Release mode opens or is refreshed. Must be read-only and need no network. | Apps (brands), each with its version in code, its tracks, the latest build per track, commits since each, and recent builds with notes |
| `plan` | When the person chooses an action (a new TestFlight build, an App Store tag). Build Desk appends the action's inputs as `--name value` pairs. Must change nothing. | The steps that would happen, in words, and a preview of the notes |
| `run` | Only after the person confirms a plan. Same inputs as `plan`. | What was done (for example the tag that was created and pushed), or a failure with its reason |
| `checks` | From Release check; optionally with `--archive <path>` for a build Build Desk made. | A list of gates, each passed, failed or skipped, with a message |
| `store` | Optional. Live state from the store: cloud build status and tester groups per build. | Per build: build state, groups, and whether the store is connected |

Rules for a provider:

- `status` and `plan` never change anything, locally or remotely.
- `run` is the only command that changes anything, and it does exactly what the matching `plan` described.
- A failure is JSON too (`{"error": "…"}`) with a non-zero exit, so Build Desk can show the reason.
- Store credentials stay with the provider (for example in the Keychain). Build Desk never asks for or sees them.
- The contract carries a `version` number; Build Desk refuses a version it does not know with a clear message.

The JSON shapes are fixed in step R0 and described in a schema file beside `builddesk.schema.json`.

## What Release mode shows

- **App switcher** when the project has more than one app.
- **Summary cards:** version in code, App Store, and one card per track with its latest build and commits since.
- **Actions:** New TestFlight build, App Store tag, Release check. Each opens a sheet.
- **Builds table:** build, track, cloud build state, tester group. Selecting a build shows its notes, its commits
  and the actions on it.
- **Store connection:** connected, or not connected with the provider's own instruction for connecting.

The action sheet shows the plan ("what will happen", numbered) and the notes preview. Its confirm button names
the action in full ("Create tag and push"). Nothing is run from a preview.

## What Build Desk adds beyond a release page

- **Install a tagged build's source on a device:** select a build in the table and build that tag onto a phone.
- **Check what was just built:** run the provider's checks on the build Build Desk produced, before tagging.
- **Release status in the menu bar:** the state of the running cloud build beside the pins, and a notification when
  a build reaches testers.
- **History:** release actions join the run history, with who tagged what from which branch.

## Steps

| Step | Result | Where |
|---|---|---|
| R0 Contract (done 2026-11-13) | The contract and its schema; the `release` section of `.builddesk.json`; a provider for the first project that prints status, plan and run as JSON | Both repositories |
| R1 Read-only Release mode (done 2026-11-13) | The status view: app switcher, summary cards, builds table, notes and commits per build | Build Desk |
| R2 Tagging (done 2026-11-13) | New TestFlight build and App Store tag, each with the plan preview and a confirmation | Build Desk |
| R3 Store (reading done 2026-11-13) | Live cloud build and tester state per build; edit the tester notes; add a build to its tester group | Build Desk, provider |
| R4 Build Desk extras (menu bar status done 2026-11-13) | Checks on a local build, install a tagged build on a device, menu bar status and notifications | Build Desk |

R1 and R2 need no store credentials. R3 shows "not connected" until the person has connected the provider.

## What R0 built

| Part | Where | What it does |
|---|---|---|
| Contract types | `ReleaseStatus`, `ReleaseApp`, `ReleaseTrack`, `ReleaseBuild`, `ReleaseAction`, `ReleasePlan`, `ReleaseResult` | The JSON shapes of contract version 1, with unknown fields ignored and a newer version refused with a clear message. |
| Client | `ReleaseClient`, `ReleaseProvider` | Runs the project's commands from the folder of its settings file, adds the action as flags, passes written notes as a temporary file and the confirmed plan's commit as `--expect`. A provider's own error words are shown as they are. |
| Settings | `ProjectConfig.release`, `ReleaseCommands` | The `release` section of `.builddesk.json`: `status` (required), `plan`, `run`, and the reserved `checks` and `store`. |
| Command line | `builddesk release status`, `builddesk release plan` | Shows where each app stands and previews an action. Running an action is left to the app, behind a confirmation. |
| Document | `docs/release-contract.md`, `docs/builddesk.schema.json` | What a provider must print, with examples. |

Tried with the first provider: status came back in about a second (two apps, four tracks, 60 recent builds), and a
plan for a new test build returned the next build's name, three steps and its generated notes. Nothing was tagged:
`run` was not called, because it pushes a tag and starts a cloud build.

Answers to two open points: a plan does contact the remote (the provider fetches tags to find the next build
number), and it takes about ten seconds, so the app must show that it is working. The provider had no
command-line status command; one was added there.

## What R1 built

| Part | Where | What it does |
|---|---|---|
| Model | `ReleaseModel`, `WindowMode` | Reads the status through the project's commands, keeps the chosen app and open build across refreshes, and shows a provider's failure in its own words with a retry. |
| Window | `ReleaseView`, the mode switch in the toolbar | A Build / Release switch appears only for a project with release commands. Release mode shows an app switcher, the checkout it was read from, summary cards (version in code, on the store, one per track) and the recent builds; a build opens in place to show its name, commit, branch and first line of notes. |
| Checks | `--snapshot --release` | Renders Release mode with the demo, or with a real project when `--project` is given. |

Tried with the first provider: two apps, their four tracks and sixty recent builds were shown from its real data.

A build's full notes and its commits are not shown yet: the contract has no command for one build's details.

## What R2 built

| Part | Where | What it does |
|---|---|---|
| Action | `ReleaseActionModel`, `ReleaseModel.begin` | Holds what the person chose (track, branch, written notes, or the shipped build), the plan the project answered with, and the run. Any change to the inputs throws the plan away, so a plan is only ever confirmed for exactly what it was made for. |
| Sheet | `ReleaseActionSheet` | New Test Build and Store Release each open a sheet: choose, press Preview, read "what will happen" with its warnings and notes, then press a button that names what it will create. A track whose notes are written by hand shows an editor and refuses a preview without notes. |
| After | `ReleaseModel.endAction` | A refused run (for example, the code moved) shows the provider's words and asks for a new preview. After a run that happened, the status is read again to show the new build. |

The run path was not tried against the first provider, on purpose: it pushes a tag and starts a cloud build. It is
covered by tests on both sides (a fake provider here, a recorded script runner there). The preview path was tried
for real in R0.

## What R3 built so far

| Part | Where | What it does |
|---|---|---|
| Contract | `ReleaseStoreStatus`, `ReleaseStoreBuild`, the `store` command | Per build: how its cloud run went (running, succeeded, failed), its testing state in words and its tester groups; per app: the versions on the store's side and alerts. "Not connected" is an answer with the provider's instruction, not an error. |
| Model | `ReleaseModel.store`, `storeBuild(for:)`, `storeNote` | The store is asked after the status, so the status shows at once and the live part fills in. A failure or a missing connection leaves the status usable and adds one line saying why. |
| Window | `ReleaseView` | Each build shows its cloud result and testing state; opening it adds the store build number, the workflow and the tester groups. A card shows the version being prepared on the store. Alerts appear at the top. |
| Command line | `builddesk release store` | The same state as a table or JSON. |

Tried with the first provider and a real store key: both apps' builds came back with their cloud results, testing
state and groups in about six seconds, including one build whose cloud run had failed.

Not built in R3: editing the tester notes of a build and adding a build to a tester group. Both write to the store
on the person's behalf, so they need a decision on how the contract describes per-build actions, and they cannot
be tried without changing a real build.

## What R4 built so far

| Part | Where | What it does |
|---|---|---|
| Watch | `ReleaseWatch`, `ReleaseWatchModel` | While Build Desk is open and the project has a `store` command, the status and the store are read again: every minute while a cloud build is running, every 15 minutes otherwise (`BuildDeskConstants.ReleaseWatch`). It only runs the `status` and `store` commands. |
| Notifications | `ReleaseChange`, `RunNotice.make(for:appName:)` | Two readings are compared. A cloud build that ended (succeeded or failed) and a build that reached testers are each announced once. The first reading, a reading after "not connected" and a state that did not move announce nothing. Someone looking at Release mode is not told what is already on screen. |
| Menu bar | `MenuBarReleaseSection`, `ReleaseModel.menuLines` | The popover has a Releases part: one line per app with its version and where its running or newest build stands, the number of alerts, and Open Release, which shows Release mode in the window. |
| Setting | Settings, "Watch release builds" | On by default; off stops the reading. |

Tried with the first provider and a real store key: the popover showed both apps with their newest build and its
testing state after one reading of about eight seconds. A change between two readings was tried with made-up
data only, because a real one needs a real cloud build.

Not built in R4: checks on a local build (the provider's checks command prints text, not JSON, today) and
installing a tagged build on a device (it means building a commit other than the checkout).

## The first provider

The first project to provide the contract already has the pieces as command-line tools:

- A command that creates a TestFlight tag for a track, with `--plan`, `--yes` and `--json`.
- A command that creates the App Store tag on the shipped build, with the same flags.
- A go or no-go check that takes an archive.
- A live store status command, and login and logout commands that keep the key in the Keychain.
- A tracks file that lists the apps, their tracks, tag prefixes and tester groups.
- Status logic (latest tag per track, commits since, notes per tag) used today by its web console.

What R0 adds there: one command-line entry that prints the status as JSON (the logic exists but is reached only
through the web console's server), and thin wrappers so that status, plan, run, checks and store print the
contract's shapes.

## Safety

- **Pushing a tag starts a cloud build and cannot be taken back quietly**, so `run` is reached only from a confirmed
  plan, never from a pin, the queue, the schedule or the menu bar.
- **Vendor and partner guards stay in the provider.** Build Desk passes the action on; it does not decide who may
  receive a build.
- **A plan that is stale is refused.** If the checkout moved between the plan and the confirmation, Build Desk asks
  for a new plan in place of running the old one.
- **Everything is logged:** each `run` goes into the run history with its inputs and result.

## Open points

| Point | Needed for | Notes |
|---|---|---|
| Where the builds table gets cloud build state without store access | R1 | Without `store`, the table shows tags and notes only. |
| Per-person or shared store key | R3 | The provider decides; Build Desk only shows connected or not. |
| Sizes | All | R0 and R1 about a week together, R2 a few days, R3 about a week, R4 about a week. Estimates, not measured. |

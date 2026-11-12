# The release contract

How a project gives Build Desk a Release mode. The project supplies commands that print JSON; Build Desk draws
the UI and runs the project's own commands for every action. Contract version: 1.

The plan this belongs to is in [RELEASE-INTEGRATION.md](RELEASE-INTEGRATION.md).

## Declaring the commands

In the project's `.builddesk.json`. Each command is an argument list, run from the folder that holds the file.
A first argument with a slash (`./tool`) is taken relative to that folder; a bare name (`python3`) is found through
the `PATH`.

```json
{
  "release": {
    "status": ["./tool", "release", "status"],
    "plan": ["./tool", "release", "plan"],
    "run": ["./tool", "release", "run"]
  }
}
```

Only `status` is required. Without `plan` and `run`, Release mode is read-only.

## Rules for every command

- Print one JSON object on standard output and nothing else there. Progress and logs go to standard error.
- Include `"contract": 1`.
- On failure, exit with a non-zero code and print `{"error": "what happened and what to do"}`. Build Desk shows
  those words.
- `status` and `plan` change nothing. `run` is the only command that changes anything, and it does exactly what
  the matching `plan` described.
- Store credentials stay with the provider. Build Desk never asks for or sees them.

## `status`

Called with no extra arguments when Release mode opens or is refreshed. It should need no network.

```json
{
  "contract": 1,
  "head": {"branch": "develop", "commit": "a41c9e2…", "subject": "Fix the cart total", "dirty": false},
  "apps": [
    {
      "id": "shop",
      "name": "Shop",
      "version": "4.2",
      "tracks": [
        {"id": "internal", "name": "Internal testers", "notes": "generated", "commitsSince": 14,
         "latest": {"id": "ShopInternal-4.2.3", "app": "shop", "track": "internal", "kind": "testflight",
                    "version": "4.2.3", "commit": "9f0c…", "date": 1794472609, "branch": "develop",
                    "notes": "Faster search"}}
      ],
      "store": {"id": "ShopStore-4.1", "app": "shop", "track": null, "kind": "store", "version": "4.1",
                "date": 1793406507, "from": "ShopInternal-4.1.9"},
      "commitsSinceStore": 120
    }
  ],
  "builds": [],
  "branches": ["develop", "main"]
}
```

| Field | Meaning |
|---|---|
| `head` | The checkout the status was read from. Optional. |
| `apps` | One entry per app the project ships. |
| `apps[].version` | The version in the code right now. |
| `apps[].tracks` | Lines of test builds, such as internal testers and outside partners. |
| `tracks[].notes` | `generated`: the provider writes a new build's notes. `written`: the person must write them. |
| `tracks[].latest` | The newest build on the track, or null. |
| `apps[].store` | What is on the store, or null. |
| `builds` | Recent builds across all apps, newest first. |
| `branches` | Branches a test build can be made from. Leave out if only the checkout can be built. |

A build has `id` (unique in the project, for example its tag), `app`, `track` (null for a store build), `kind`
(`testflight` or `store`), `version` (as shown to people), and optionally `commit`, `date` (seconds since 1970),
`branch`, `notes` (first line) and `from` (for a store build: the test build that was shipped).

## `plan`

Called when the person chooses an action. Build Desk appends the action as flags:

| Flag | Value |
|---|---|
| `--action` | `testflight` (a new test build) or `store` (mark a build as the store release) |
| `--app` | The app's `id` |
| `--track` | For `testflight`: the track's `id` |
| `--branch` | For `testflight`: the branch to build. Left out to build the checkout. |
| `--from` | For `store`: the `id` of the test build that was shipped |
| `--notes-file` | A file with the notes the person wrote, for a track whose notes are `written` |

```json
{
  "contract": 1,
  "title": "ShopInternal-4.2.4",
  "steps": ["Create tag ShopInternal-4.2.4 on a41c9e2", "Push the tag, which starts the cloud build"],
  "notes": "Faster search\nFixes the cart total",
  "commit": "a41c9e2…",
  "warnings": []
}
```

`steps` are shown to the person as "what will happen", in order. A plan may contact the remote (for example to
find the next build number) but must not change the project.

## `run`

Called only after the person has confirmed a plan, with the same flags as `plan` plus `--expect <commit>`: the
`commit` of the plan that was confirmed. If the code has moved since, refuse with an error; Build Desk then asks
for a new plan.

```json
{"contract": 1, "result": "ShopInternal-4.2.4", "done": ["Created tag ShopInternal-4.2.4", "Pushed the tag"]}
```

## `store`

Optional. Called after `status`, with no extra arguments. It may use the network. It is read-only.

```json
{
  "contract": 1,
  "connected": true,
  "hint": null,
  "apps": [
    {
      "id": "shop",
      "builds": [
        {"id": "ShopInternal-4.2.3", "number": "812", "cloud": "succeeded", "cloudDetail": "Release workflow",
         "testing": "In testing", "groups": ["Staff"]}
      ],
      "storeVersions": [{"version": "4.2", "state": "Prepare for submission"}],
      "alerts": [{"severity": "warning", "message": "Build 800 is in a partner group"}]
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `connected` | False when the provider has no access to the store on this Mac. Then `hint` says what to do, and `apps` is empty. This is an answer, not an error. |
| `builds[].id` | The same id as the build in `status`, which is how the two are matched. |
| `builds[].cloud` | `running`, `succeeded` or `failed`: how the build's cloud run went. |
| `builds[].testing` | The testing state in words; null until the build has reached testers. |
| `builds[].groups` | The tester groups that have the build. |
| `storeVersions` | Versions on the store's side with their state, newest first. |
| `alerts` | Things that need attention; `severity` is `error` or `warning`. |

## Later versions

`checks` (go or no-go gates) is a reserved name in the settings file; its shape is added to this document when
Build Desk reads it.

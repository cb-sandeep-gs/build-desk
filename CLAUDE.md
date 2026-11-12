# Build Desk — working rules

Plan and phase status: [docs/PLAN.md](docs/PLAN.md). Work one phase (BD-n) at a time; each phase ends with tests
and docs.

## Code
- **BuildDeskCore holds all logic.** The CLI and the app stay thin layers over it.
- **Apple tools only through one client.** argv lists only, never a shell string. Parse machine-readable output
  (`-json`, `--json-output`) only, never human-readable text.
- **Never pass `-derivedDataPath`.** Builds go to Xcode's own DerivedData so they stay shared and incremental; a
  private copy of a large app costs 8–13 GB.
- **Never change the user's project or checkout.** Build Desk reads projects and runs builds; it writes only its
  own logs and settings.
- **Nothing project-specific in code.** Project differences belong in `.builddesk.json` at that project's root.
- **No magic numbers or strings:** use a named constant.
- Swift 6 language mode, strict concurrency. No new dependencies without discussion.
- Comment the why, briefly.

## Git
- Conventional Commits (`feat(core): …`), no AI/tool attribution trailers.
- Commit locally per phase; push only when the user asks.

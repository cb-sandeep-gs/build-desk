# Build Desk

Build any scheme of an Xcode project, install it on a connected iPhone or iPad and launch it, without opening
Xcode.

Build Desk drives the command-line tools that ship inside Xcode (`xcodebuild`, `devicectl`, `simctl`), so Xcode
must be installed but never needs to be running. Signing uses the Apple account already saved in Xcode.

**Status:** phase BD-0 (command-line proof) is done. The Swift core is next (BD-1); the Mac app comes in BD-2. See [docs/PLAN.md](docs/PLAN.md).

## Try the proof script

Requirements: macOS with Xcode installed, a device that has been paired with this Mac once, and Xcode closed.

```bash
# Schemes, targets and configurations of a project (JSON)
./Scripts/phase0-proof.sh schemes /path/to/App.xcodeproj

# Connected and known devices (JSON), including each device's UDID
./Scripts/phase0-proof.sh devices

# Build, install and launch
./Scripts/phase0-proof.sh run /path/to/App.xcodeproj <scheme> <device-udid> [configuration]
```

`configuration` defaults to `Debug`. Set `BUILDDESK_NO_LAUNCH=1` to stop after the install. Full logs of each run
are kept in `~/Library/Logs/BuildDesk` (override with `BUILDDESK_LOG_DIR`).

The build goes into Xcode's normal DerivedData folder, so it is incremental with builds made from Xcode itself.

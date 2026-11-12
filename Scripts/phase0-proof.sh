#!/bin/bash
#
# Build Desk — phase 0 proof.
#
# Proves the whole "never open Xcode" flow from the command line before any
# app code exists: list schemes, list devices, build a scheme for one device,
# install the built app and launch it. Every step uses the same Apple tools
# (xcodebuild, devicectl) and the same machine-readable output the Swift core
# will parse in phase 1, so what works here is what the app will do.
#
# Usage:
#   phase0-proof.sh schemes <project-or-workspace>
#   phase0-proof.sh devices
#   phase0-proof.sh run <project-or-workspace> <scheme> <device-udid> [configuration]
#
# Environment:
#   BUILDDESK_LOG_DIR   where full build logs go (default ~/Library/Logs/BuildDesk)
#   BUILDDESK_NO_LAUNCH set to 1 to stop after the install step

set -euo pipefail

readonly DEFAULT_CONFIGURATION="Debug"
readonly APPLICATION_PRODUCT_TYPE="com.apple.product-type.application"
readonly LOG_DIR="${BUILDDESK_LOG_DIR:-$HOME/Library/Logs/BuildDesk}"
# Lines of the build log shown when a step fails; the full log stays on disk.
readonly FAILURE_TAIL_LINES=40

usage() {
  sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit 64
}

fail() {
  echo "error: $*" >&2
  exit 1
}

# xcodebuild takes -workspace or -project depending on the container type.
container_flag() {
  case "$1" in
    *.xcworkspace) echo "-workspace" ;;
    *.xcodeproj) echo "-project" ;;
    *) fail "expected a .xcodeproj or .xcworkspace path, got: $1" ;;
  esac
}

# An open Xcode can hold the build database and make a command-line build fail
# at CreateBuildDescription, so say so up front instead of failing 2 minutes in.
warn_if_xcode_open() {
  if pgrep -x Xcode >/dev/null; then
    echo "warning: Xcode is open; command-line builds can fail while it holds the build folder." >&2
  fi
}

# Runs one step, prints how long it took, and keeps its full output in a log.
# Arguments: <step name> <log file> <command...>
run_step() {
  local name="$1" log="$2"
  shift 2
  local started=$SECONDS
  printf '==> %-8s ' "$name"
  if "$@" >"$log" 2>&1; then
    echo "ok   $((SECONDS - started)) s"
  else
    echo "FAILED after $((SECONDS - started)) s (full log: $log)"
    tail -n "$FAILURE_TAIL_LINES" "$log" >&2
    exit 1
  fi
}

list_schemes() {
  local container="$1"
  xcodebuild -list -json "$(container_flag "$container")" "$container"
}

list_devices() {
  # devicectl only writes JSON to a file; its stdout is the human table.
  local json
  json="$(mktemp -t builddesk-devices)"
  xcrun devicectl list devices --json-output "$json" >/dev/null
  jq '[.result.devices[] | {
        name: .deviceProperties.name,
        udid: .hardwareProperties.udid,
        model: .hardwareProperties.marketingName,
        platform: .hardwareProperties.platform,
        reality: .hardwareProperties.reality,
        transport: .connectionProperties.transportType,
        pairing: .connectionProperties.pairingState,
        tunnel: .connectionProperties.tunnelState,
        os: .deviceProperties.osVersionNumber
      }]' "$json"
  rm -f "$json"
}

build_install_launch() {
  local container="$1" scheme="$2" udid="$3" configuration="${4:-$DEFAULT_CONFIGURATION}"
  local flag
  flag="$(container_flag "$container")"
  [ -e "$container" ] || fail "no such project: $container"
  warn_if_xcode_open
  mkdir -p "$LOG_DIR"

  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  local build_log="$LOG_DIR/$stamp-build.log"
  local settings_json="$LOG_DIR/$stamp-settings.json"
  local install_log="$LOG_DIR/$stamp-install.log"
  local launch_log="$LOG_DIR/$stamp-launch.log"

  # One argument list for both the build and the settings query, so the app
  # path we install is exactly the one this build produced. No -derivedDataPath:
  # the build lands in Xcode's own DerivedData and stays incremental with it.
  local -a xcode_args=(
    "$flag" "$container"
    -scheme "$scheme"
    -configuration "$configuration"
    -destination "id=$udid"
    -allowProvisioningUpdates
  )

  local total_started=$SECONDS
  run_step "build" "$build_log" xcodebuild "${xcode_args[@]}" build

  # The scheme can build several targets (extensions, watch app); the one to
  # install is the application product.
  run_step "locate" "$settings_json" xcodebuild "${xcode_args[@]}" -showBuildSettings -json
  local app_path bundle_id
  app_path="$(jq -r --arg type "$APPLICATION_PRODUCT_TYPE" \
    '[.[] | select(.buildSettings.PRODUCT_TYPE == $type)][0]
     | .buildSettings | "\(.TARGET_BUILD_DIR)/\(.WRAPPER_NAME)"' "$settings_json")"
  bundle_id="$(jq -r --arg type "$APPLICATION_PRODUCT_TYPE" \
    '[.[] | select(.buildSettings.PRODUCT_TYPE == $type)][0]
     | .buildSettings.PRODUCT_BUNDLE_IDENTIFIER' "$settings_json")"
  [ -d "$app_path" ] || fail "scheme '$scheme' has no built application at: $app_path"
  echo "    app:    $app_path"
  echo "    bundle: $bundle_id"

  run_step "install" "$install_log" xcrun devicectl device install app --device "$udid" "$app_path"

  if [ "${BUILDDESK_NO_LAUNCH:-0}" != "1" ]; then
    # --terminate-existing so a running copy is replaced by the new build.
    run_step "launch" "$launch_log" xcrun devicectl device process launch \
      --device "$udid" --terminate-existing "$bundle_id"
  fi

  echo "done in $((SECONDS - total_started)) s (logs: $LOG_DIR/$stamp-*)"
}

command_name="${1:-}"
[ -n "$command_name" ] || usage
shift

case "$command_name" in
  schemes) [ $# -eq 1 ] || usage; list_schemes "$1" ;;
  devices) [ $# -eq 0 ] || usage; list_devices ;;
  run) [ $# -ge 3 ] && [ $# -le 4 ] || usage; build_install_launch "$@" ;;
  *) usage ;;
esac

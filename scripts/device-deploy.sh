#!/usr/bin/env bash
# Build the PrivateInventory app for a physical iOS device and install it
# via devicectl (launching it unless --no-launch is given).
#
# Usage (from repo root or any CWD):
#   ./scripts/device-deploy.sh --team-id <TEAM_ID>
#     [--device <name-or-id>] [--configuration <Debug|Release>] [--no-launch]
#
# Default configuration: Release. With multiple paired iOS devices
# connected, --device is required.
# Builds via the scheme; the scheme's build action covers only the app
# (the test bundle has buildForRunning=NO, it is built only for tests).
# Output goes through xcbeautify when it is installed (compact,
# token-saving for agent contexts); otherwise raw xcodebuild output.
set -euo pipefail

# Resolve paths relative to this script so it works from any CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

usage() {
  cat <<'EOF'
Usage: ./scripts/device-deploy.sh --team-id <TEAM_ID> [--device <name-or-id>] [--configuration <Debug|Release>] [--no-launch]

  --team-id <id>                  Apple development team id (required)
  --device <name-or-id>           Device name or id; default: the only paired iOS device
  --configuration <Debug|Release> Build configuration; default: Release
  --no-launch                     Install only, skip launching the app
  -h, --help                      Show this help
EOF
}

require_value() { # $1 = flag name; errors if no (non-flag) value follows it
  if [[ $# -lt 2 || "${2}" == --* ]]; then
    echo "error: ${1} requires a value" >&2
    usage >&2
    exit 1
  fi
}

TEAM_ID=""
DEVICE_ARG=""
CONFIGURATION="Release"
LAUNCH=1

while (( $# > 0 )); do
  case "$1" in
    --team-id)       require_value "$@"; TEAM_ID="$2"; shift 2 ;;
    --device)        require_value "$@"; DEVICE_ARG="$2"; shift 2 ;;
    --configuration) require_value "$@"; CONFIGURATION="$2"; shift 2 ;;
    --no-launch)     LAUNCH=0; shift ;;
    --help|-h)       usage; exit 0 ;;
    *)               echo "error: unknown flag: ${1}" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "${TEAM_ID}" ]]; then echo "error: --team-id is required" >&2; usage >&2; exit 1; fi

case "${CONFIGURATION}" in
  Debug|Release) ;;
  *) echo "error: --configuration must be Debug or Release, got '${CONFIGURATION}'" >&2; usage >&2; exit 1 ;;
esac

# Paired iOS devices from the devicectl JSON as "identifier<TAB>name" lines.
mkdir -p build
DEVICECTL_JSON="build/devicectl-devices.json"
rm -f "${DEVICECTL_JSON}"
xcrun devicectl list devices --json-output "${DEVICECTL_JSON}"

PAIRED_DEVICES="$(python3 -c "
import json, sys
for d in json.load(open(sys.argv[1])).get('result', {}).get('devices', []):
    if d.get('hardwareProperties', {}).get('platform') == 'iOS' and d.get('connectionProperties', {}).get('pairingState') == 'paired':
        print(f\"{d.get('identifier', '')}\t{d.get('deviceProperties', {}).get('name', '<unknown>')}\")
" "${DEVICECTL_JSON}")"

list_paired_devices() {
  while IFS=$'\t' read -r id name; do
    if [[ -n "${id}" ]]; then
      printf '  - %s (%s)\n' "${name}" "${id}"
    fi
  done <<< "${PAIRED_DEVICES}"
}

PAIRED_COUNT="$(grep -c . <<< "${PAIRED_DEVICES}" || true)"
if [[ -n "${DEVICE_ARG}" ]]; then
  MATCHED_LINE="$(awk -F '\t' -v q="${DEVICE_ARG}" '$1 == q || $2 == q { print; exit }' <<< "${PAIRED_DEVICES}")"
  if [[ -z "${MATCHED_LINE}" ]]; then
    echo "error: no paired iOS device matches --device '${DEVICE_ARG}'. Paired iOS devices:" >&2
    list_paired_devices
    exit 1
  fi
  IFS=$'\t' read -r DEVICE_ID DEVICE_NAME <<< "${MATCHED_LINE}"
elif (( PAIRED_COUNT == 1 )); then
  IFS=$'\t' read -r DEVICE_ID DEVICE_NAME <<< "${PAIRED_DEVICES}"
elif (( PAIRED_COUNT == 0 )); then
  echo "error: no paired iOS device is connected. Paired iOS devices found: none." >&2
  exit 1
else
  echo "error: multiple paired iOS devices are connected, specify one with --device:" >&2
  list_paired_devices
  exit 1
fi

# Bundle identifier from the project (single source of truth, no hardcoding).
PROJECT_FILE="app/PrivateInventory.xcodeproj/project.pbxproj"
BUNDLE_ID="$(grep -E 'PRODUCT_BUNDLE_IDENTIFIER = [^;]+;' "${PROJECT_FILE}" \
  | sed -E 's/.*PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);.*/\1/' | sort -u | grep -v '\.tests$' || true)"
if [[ -z "${BUNDLE_ID}" || "${BUNDLE_ID}" == *$'\n'* ]]; then echo "error: could not determine a single bundle identifier from ${PROJECT_FILE}" >&2; exit 1; fi

DERIVED_DATA="build/DerivedData"

echo "Building ${CONFIGURATION} build for ${DEVICE_NAME} (${DEVICE_ID})..."
XCODEBUILD_ARGS=(
  -project app/PrivateInventory.xcodeproj
  -scheme PrivateInventory
  -destination "platform=iOS,id=${DEVICE_ID}"
  -configuration "${CONFIGURATION}"
  -derivedDataPath "${DERIVED_DATA}"
  DEVELOPMENT_TEAM="${TEAM_ID}"
  -allowProvisioningUpdates
  CODE_SIGN_STYLE=Automatic
)

if command -v xcbeautify >/dev/null 2>&1; then
  xcodebuild "${XCODEBUILD_ARGS[@]}" build | xcbeautify
else
  xcodebuild "${XCODEBUILD_ARGS[@]}" build
fi

APP_PATH="${DERIVED_DATA}/Build/Products/${CONFIGURATION}-iphoneos/PrivateInventory.app"

echo "Installing on ${DEVICE_NAME} (${DEVICE_ID})..."
xcrun devicectl device install app --device "${DEVICE_ID}" "${APP_PATH}"

if (( LAUNCH )); then
  if ! xcrun devicectl device process launch --device "${DEVICE_ID}" "${BUNDLE_ID}"; then
    echo "error: launching failed (a locked device refuses launches). The app IS installed — unlock ${DEVICE_NAME} and start it manually, or re-run this script." >&2
    exit 1
  fi
  echo "Done: installed on ${DEVICE_NAME} (${DEVICE_ID}), configuration ${CONFIGURATION}, launched."
else
  echo "Done: installed on ${DEVICE_NAME} (${DEVICE_ID}), configuration ${CONFIGURATION}."
fi

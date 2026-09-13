#!/usr/bin/env bash
# Build the PrivateInventory app for the iOS Simulator (iPhone 17).
#
# Usage (from repo root or any CWD):
#   ./scripts/build.sh
#
# Output goes through xcbeautify when it is installed (compact,
# token-saving for agent contexts); otherwise raw xcodebuild output.
# Failure details: build/PrivateInventory.xcresult
set -euo pipefail

# Resolve paths relative to this script so it works from any CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

RESULT_BUNDLE="build/PrivateInventory.xcresult"
rm -rf "${RESULT_BUNDLE}"

XCODEBUILD_ARGS=(
  -project app/PrivateInventory.xcodeproj
  -scheme PrivateInventory
  -destination 'platform=iOS Simulator,name=iPhone 17'
  CODE_SIGNING_ALLOWED=NO
  -resultBundlePath "${RESULT_BUNDLE}"
)

if command -v xcbeautify >/dev/null 2>&1; then
  xcodebuild "${XCODEBUILD_ARGS[@]}" build | xcbeautify
else
  xcodebuild "${XCODEBUILD_ARGS[@]}" build
fi

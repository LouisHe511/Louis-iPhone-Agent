#!/bin/bash
# Offline Simulator validation only. Pass the UDID of an already booted simulator.
set -euo pipefail
if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <booted-simulator-UDID>  (RUN_UI_TESTS=1 also runs UI tests)" >&2
  exit 2
fi
project_root="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p "$project_root/.build/background-runs"
validation_dir="$(mktemp -d "$project_root/.build/background-runs/run.XXXXXX")"
cat > "$validation_dir/isolated.xcconfig" <<'CONFIG'
PRODUCT_BUNDLE_IDENTIFIER = com.ja1chen.$(TARGET_NAME).BackgroundValidation
CONFIG
selection=(-only-testing:PhoneAgentTests)
if [ "${RUN_UI_TESTS:-0}" = 1 ]; then selection+=(-only-testing:PhoneAgentUITests); fi
if xcodebuild -project "$project_root/PhoneAgent.xcodeproj" -scheme PhoneAgent \
    -configuration Debug -destination "platform=iOS Simulator,id=$1" \
    -derivedDataPath "$project_root/DerivedData" -xcconfig "$validation_dir/isolated.xcconfig" \
    -resultBundlePath "$validation_dir/Tests.xcresult" "${selection[@]}" \
    test CODE_SIGNING_ALLOWED=NO > "$validation_dir/tests.log" 2>&1; then
  tail -12 "$validation_dir/tests.log"
  echo "Evidence: $validation_dir"
else
  tail -60 "$validation_dir/tests.log"
  echo "Failed; full log: $validation_dir/tests.log" >&2
  exit 1
fi

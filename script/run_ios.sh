#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
device_id="${1:-${WHISPER_IOS_DEVICE_ID:-}}"
if [[ $# -gt 0 ]]; then shift; fi
flutter_bin="${WHISPER_FLUTTER_BIN:-flutter}"
if [[ -z "$device_id" ]]; then
  device_id="$("$flutter_bin" devices --machine | python3 -c '
import json, sys
devices = [d for d in json.load(sys.stdin) if d.get("targetPlatform") == "ios" and not d.get("emulator")]
if len(devices) != 1:
    sys.exit("请连接一台已信任的 iPhone/iPad，或通过第一个参数指定设备 ID")
print(devices[0]["id"])
')"
fi

# A release build can launch from the Home Screen without a debugger attached.
# Keep signing credentials in Xcode; FLUTTER_XCODE_DEVELOPMENT_TEAM is optional.
"$flutter_bin" build ios --release --no-pub --target lib/main.dart "$@"
# Resolve Xcode's actual output: Flutter's shared iphoneos copy can be stale
# when switching between debug, profile, and release configurations.
app_path="$(xcrun xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner \
  -configuration Release -sdk iphoneos -showBuildSettings -json \
  "BUILD_DIR=$project_root/build/ios" | python3 -c '
import json, os, sys
runner = next(item["buildSettings"] for item in json.load(sys.stdin) if item["target"] == "Runner")
print(os.path.join(runner["TARGET_BUILD_DIR"], runner["FULL_PRODUCT_NAME"]))
')"
xcrun devicectl device install app --device "$device_id" \
  --timeout 60 "$app_path"
xcrun devicectl device process launch --device "$device_id" \
  --terminate-existing com.vireen.whisper

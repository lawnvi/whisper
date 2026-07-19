#!/usr/bin/env bash
case "${BASH:-}" in
  */bash|bash) ;;
  *) exec /usr/bin/env bash "$0" "$@" ;;
esac

set -euo pipefail

MODE="${1:-run}"
APP_NAME="whisper"
DEBUG_APP_BUNDLE="build/macos/Build/Products/Debug/whisper.app"
RELEASE_APP_BUNDLE="build/macos/Build/Products/Release/whisper.app"
DEBUG_ENTITLEMENTS="macos/Runner/DebugProfile.entitlements"
RELEASE_ENTITLEMENTS="macos/Runner/Release.entitlements"
SIGN_IDENTITY="${WHISPER_MACOS_SIGN_IDENTITY:-Whisper Local Development}"
RESOLVED_SIGN_IDENTITY=""
KEYCHAIN="${WHISPER_MACOS_KEYCHAIN:-${HOME}/Library/Keychains/login.keychain-db}"
KEYCHAIN_PASSWORD="${WHISPER_MACOS_KEYCHAIN_PASSWORD:-whisper-ci}"
CERTIFICATE_P12_BASE64="${WHISPER_MACOS_CERTIFICATE_P12_BASE64:-}"
CERTIFICATE_PASSWORD="${WHISPER_MACOS_CERTIFICATE_PASSWORD:-}"
REQUIRE_STABLE_SIGNING="${WHISPER_MACOS_REQUIRE_STABLE_SIGNING:-0}"
DMG_ROOT="${WHISPER_MACOS_DMG_ROOT:-dmg-root}"
DMG_PATH="${WHISPER_MACOS_DMG_PATH:-whisper.dmg}"
DMG_APP_BUNDLE_NAME="Whisper.app"
DMG_WINDOW_BOUNDS="{160, 120, 720, 440}"
DMG_ICON_SIZE=112
DMG_APP_ICON_POSITION="{180, 170}"
DMG_APPLICATIONS_ICON_POSITION="{420, 170}"
TEMP_DIRS=()

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

cleanup_temp_dirs() {
  if [[ ${#TEMP_DIRS[@]} -eq 0 ]]; then
    return
  fi

  local temp_dir
  for temp_dir in "${TEMP_DIRS[@]}"; do
    rm -rf "$temp_dir"
  done
}
trap cleanup_temp_dirs EXIT

ensure_local_signing_identity() {
  if security find-certificate -c "$SIGN_IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    return
  fi

  local tmpdir
  tmpdir="$(mktemp -d)"
  TEMP_DIRS+=("$tmpdir")

  openssl req -newkey rsa:2048 -nodes \
    -keyout "$tmpdir/key.pem" \
    -x509 -days 3650 \
    -out "$tmpdir/cert.pem" \
    -subj "/CN=$SIGN_IDENTITY/" \
    -addext "extendedKeyUsage=codeSigning" \
    -addext "keyUsage=digitalSignature" >/dev/null 2>&1

  openssl pkcs12 -legacy -export \
    -inkey "$tmpdir/key.pem" \
    -in "$tmpdir/cert.pem" \
    -out "$tmpdir/cert.p12" \
    -name "$SIGN_IDENTITY" \
    -passout pass:whisper-dev >/dev/null 2>&1

  security import "$tmpdir/cert.p12" \
    -k "$KEYCHAIN" \
    -P "whisper-dev" \
    -T /usr/bin/codesign \
    -T /usr/bin/security
}

use_ci_keychain_if_needed() {
  if [[ -n "${WHISPER_MACOS_KEYCHAIN:-}" || -z "${RUNNER_TEMP:-}" ]]; then
    return
  fi
  KEYCHAIN="$RUNNER_TEMP/whisper-signing.keychain-db"
}

unlock_signing_keychain() {
  if [[ ! -f "$KEYCHAIN" ]]; then
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
  fi
  security set-keychain-settings -lut 21600 "$KEYCHAIN"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"

  local existing_keychain
  local existing_keychains=()
  while IFS= read -r existing_keychain; do
    existing_keychain="$(
      printf '%s\n' "$existing_keychain" |
        sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//'
    )"
    if [[ -n "$existing_keychain" && "$existing_keychain" != "$KEYCHAIN" ]]; then
      existing_keychains+=("$existing_keychain")
    fi
  done < <(security list-keychains -d user)
  security list-keychains -d user -s "$KEYCHAIN" "${existing_keychains[@]}"
}

import_stable_signing_identity() {
  if [[ -z "$CERTIFICATE_P12_BASE64" ]]; then
    if [[ "$REQUIRE_STABLE_SIGNING" == "1" ]]; then
      echo "WHISPER_MACOS_CERTIFICATE_P12_BASE64 is required for stable CI signing" >&2
      exit 1
    fi
    ensure_local_signing_identity
    return
  fi
  if [[ -z "$CERTIFICATE_PASSWORD" ]]; then
    echo "WHISPER_MACOS_CERTIFICATE_PASSWORD is required when importing a signing certificate" >&2
    exit 1
  fi

  use_ci_keychain_if_needed
  unlock_signing_keychain

  local tmpdir
  tmpdir="$(mktemp -d)"
  TEMP_DIRS+=("$tmpdir")

  printf '%s' "$CERTIFICATE_P12_BASE64" |
    openssl base64 -A -d -out "$tmpdir/cert.p12"

  if ! security find-certificate -c "$SIGN_IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    security import "$tmpdir/cert.p12" \
      -k "$KEYCHAIN" \
      -P "$CERTIFICATE_PASSWORD" \
      -T /usr/bin/codesign \
      -T /usr/bin/security
    security set-key-partition-list \
      -S apple-tool:,apple:,codesign: \
      -s \
      -k "$KEYCHAIN_PASSWORD" \
      "$KEYCHAIN" >/dev/null
  fi
}

resolve_signing_identity() {
  local identity_line
  identity_line="$(
    security find-identity -p codesigning "$KEYCHAIN" |
      awk -v identity="$SIGN_IDENTITY" \
        'index($0, "\"" identity "\"") || $2 == identity { print; exit }'
  )"

  if [[ -z "$identity_line" ]]; then
    echo "Signing identity '$SIGN_IDENTITY' was not found in $KEYCHAIN" >&2
    echo "Available code signing identities in $KEYCHAIN:" >&2
    security find-identity -p codesigning "$KEYCHAIN" >&2 || true
    exit 1
  fi

  RESOLVED_SIGN_IDENTITY="$(awk '{print $2}' <<<"$identity_line")"
}

ensure_signing_identity() {
  import_stable_signing_identity
  resolve_signing_identity
}

sign_app() {
  local app_bundle="$1"
  local entitlements="$2"
  ensure_signing_identity
  /usr/bin/codesign --force --deep \
    --sign "$RESOLVED_SIGN_IDENTITY" \
    --keychain "$KEYCHAIN" \
    --entitlements "$entitlements" \
    "$app_bundle"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_bundle"
}

build_debug_app() {
  flutter build macos --debug
  dart script/prune_flutter_assets.dart macos \
    "$DEBUG_APP_BUNDLE/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets"
  sign_app "$DEBUG_APP_BUNDLE" "$DEBUG_ENTITLEMENTS"
}

build_release_app() {
  flutter build macos
  dart script/prune_flutter_assets.dart macos \
    "$RELEASE_APP_BUNDLE/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets"
  sign_app "$RELEASE_APP_BUNDLE" "$RELEASE_ENTITLEMENTS"
}

configure_dmg_finder_window() {
  local mount_point="$1"

  osascript <<EOF
tell application "Finder"
  tell disk "Whisper"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to $DMG_WINDOW_BOUNDS
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to $DMG_ICON_SIZE
    set text size of viewOptions to 13
    set position of item "$DMG_APP_BUNDLE_NAME" of container window to $DMG_APP_ICON_POSITION
    set position of item "Applications" of container window to $DMG_APPLICATIONS_ICON_POSITION
    update without registering applications
    close
  end tell
end tell
EOF

  # Finder writes .DS_Store asynchronously; give it a moment before detaching.
  sleep 1
  sync
  test -f "$mount_point/.DS_Store"
}

detach_dmg_mount() {
  local mount_point="$1"

  for _ in 1 2 3 4 5; do
    if hdiutil detach "$mount_point" -quiet; then
      return 0
    fi
    sleep 1
  done

  hdiutil detach "$mount_point" -force -quiet
}

package_release_dmg() {
  local rw_dmg_path="${DMG_PATH%.dmg}-rw.dmg"
  if [[ "$rw_dmg_path" == "$DMG_PATH" ]]; then
    rw_dmg_path="${DMG_PATH}-rw.dmg"
  fi

  local mount_point
  mount_point="$(mktemp -d)"
  TEMP_DIRS+=("$mount_point")

  rm -rf "$DMG_ROOT" "$DMG_PATH" "$rw_dmg_path"
  mkdir -p "$DMG_ROOT"
  cp -R "$RELEASE_APP_BUNDLE" "$DMG_ROOT/$DMG_APP_BUNDLE_NAME"
  ln -s /Applications "$DMG_ROOT/Applications"
  hdiutil create -volname "Whisper" -srcfolder "$DMG_ROOT" -ov -format UDRW "$rw_dmg_path"
  hdiutil attach "$rw_dmg_path" -mountpoint "$mount_point" -nobrowse -quiet
  # The Finder window layout is purely cosmetic. Headless CI runners have no
  # interactive Finder session, so scripting the mounted volume fails
  # (-1728 "Can't get disk"). Treat it as best-effort so a functional DMG is
  # still produced; require it only when explicitly demanded.
  if ! configure_dmg_finder_window "$mount_point"; then
    if [[ "${WHISPER_MACOS_REQUIRE_DMG_LAYOUT:-0}" == "1" ]]; then
      detach_dmg_mount "$mount_point" || true
      echo "Failed to configure DMG Finder window layout" >&2
      exit 1
    fi
    echo "Warning: skipping DMG Finder window layout (cosmetic); packaging plain DMG" >&2
  fi
  detach_dmg_mount "$mount_point"
  hdiutil convert "$rw_dmg_path" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
  rm -f "$rw_dmg_path"
  hdiutil verify "$DMG_PATH"
}

open_app() {
  /usr/bin/open -n "$DEBUG_APP_BUNDLE"
}

run_debug_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  build_debug_app
  open_app
}

case "$MODE" in
  run)
    run_debug_app
    ;;
  --debug|debug)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    build_debug_app
    lldb -- "$DEBUG_APP_BUNDLE/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    run_debug_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    run_debug_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --verify|verify)
    run_debug_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  package-macos|--package-macos|release|--release)
    build_release_app
    package_release_dmg
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|package-macos]" >&2
    exit 2
    ;;
esac

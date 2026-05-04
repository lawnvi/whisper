#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="whisper"
APP_BUNDLE="build/macos/Build/Products/Debug/whisper.app"
ENTITLEMENTS="macos/Runner/DebugProfile.entitlements"
SIGN_IDENTITY="${WHISPER_MACOS_SIGN_IDENTITY:-Whisper Local Development}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ensure_local_signing_identity() {
  if security find-certificate -c "$SIGN_IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    return
  fi

  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

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

sign_debug_app() {
  ensure_local_signing_identity
  /usr/bin/codesign --force --deep \
    --sign "$SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    "$APP_BUNDLE"
}

build_debug_app() {
  flutter build macos --debug
  sign_debug_app
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
build_debug_app

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

#!/usr/bin/env bash
# Writes and signs the manifest that lets the Windows lock screen input
# service update itself: the files it runs (whisper.exe and the C runtime
# shipped beside it), each with its SHA-512, and the version they were built
# as. The service, running as LocalSystem, takes newer files from the app's
# folder only when this manifest is signed with a key it trusts
# (windows/runner/input_service_manifest.cpp) and every hash matches.
#
# Usage: sign_input_service.sh <version> <release dir> <output dir>
# The key comes from UPDATE_SIGNING_KEY (Ed25519 private key, PEM), the same
# one that signs update packages; the manifest's first line keeps the two
# kinds of signature apart.
set -euo pipefail

version="${1:?usage: $0 <version> <release dir> <output dir>}"
dir="${2:?usage: $0 <version> <release dir> <output dir>}"
out="${3:?usage: $0 <version> <release dir> <output dir>}"

if [[ ! "$version" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]]; then
  echo "Not a package version: $version" >&2
  exit 1
fi
if [[ -z "${UPDATE_SIGNING_KEY:-}" ]]; then
  echo "UPDATE_SIGNING_KEY is not set; refusing to ship an unsigned input service" >&2
  exit 1
fi

sha512_of() {
  if command -v sha512sum > /dev/null; then
    sha512sum "$1" | cut -d' ' -f1
  else
    shasum -a 512 "$1" | cut -d' ' -f1
  fi
}

mkdir -p "$out"
manifest="$out/whisper_input_service.manifest"
{
  printf 'whisper-input-service-v1\n%s\n' "$version"
  for name in whisper.exe msvcp140.dll vcruntime140.dll vcruntime140_1.dll; do
    if [[ ! -f "$dir/$name" ]]; then
      echo "Missing from the Windows build: $name" >&2
      exit 1
    fi
    printf '%s %s\n' "$(sha512_of "$dir/$name")" "$name"
  done
} > "$manifest"

umask 077
key="$(mktemp)"
trap 'rm -f "$key"' EXIT
printf '%s\n' "$UPDATE_SIGNING_KEY" > "$key"
openssl pkeyutl -sign -inkey "$key" -rawin -in "$manifest" | base64 | tr -d '\n' > "$manifest.sig"
echo "Signed the input service manifest for $version"

#!/usr/bin/env bash
# Signs every package in a release directory, writing <package>.sig next to
# it. Whisper installs an update only when one of the keys in
# lib/helper/update_signature.dart signed exactly this statement:
#
#   whisper-update-v1\n<tag>\n<asset name>\n<sha256 hex>\n
#
# Usage: script/sign_update_packages.sh <tag> <directory>
# The Ed25519 private key (PEM) comes from UPDATE_SIGNING_KEY; it never touches
# the disk except in a 0600 temporary file removed on exit.
set -euo pipefail

tag="${1:?usage: $0 <tag> <directory>}"
dir="${2:?usage: $0 <tag> <directory>}"

if [[ ! "$tag" =~ ^(dev|release)-v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Not a release tag: $tag" >&2
  exit 1
fi
if [[ -z "${UPDATE_SIGNING_KEY:-}" ]]; then
  echo "UPDATE_SIGNING_KEY is not set; refusing to publish unsigned packages" >&2
  exit 1
fi

umask 077
key="$(mktemp)"
statement="$(mktemp)"
trap 'rm -f "$key" "$statement"' EXIT
printf '%s\n' "$UPDATE_SIGNING_KEY" > "$key"

sha256_of() {
  if command -v sha256sum > /dev/null; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

count=0
while IFS= read -r -d '' file; do
  name="$(basename "$file")"
  # GitHub renames assets with other characters, and the name is signed.
  if [[ ! "$name" =~ ^[A-Za-z0-9._+-]+$ ]]; then
    echo "Package name GitHub would change: $name" >&2
    exit 1
  fi
  printf 'whisper-update-v1\n%s\n%s\n%s\n' "$tag" "$name" "$(sha256_of "$file")" > "$statement"
  openssl pkeyutl -sign -inkey "$key" -rawin -in "$statement" | base64 | tr -d '\n' > "$file.sig"
  count=$((count + 1))
done < <(find "$dir" -type f ! -name '*.sig' -print0)

if [[ "$count" -eq 0 ]]; then
  echo "Nothing to sign in $dir" >&2
  exit 1
fi
echo "Signed $count packages for $tag"

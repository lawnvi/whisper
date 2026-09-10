#!/usr/bin/env bash
set -euo pipefail

# Jammy has no libei development package. Build against its libc so the same
# release bundle supports X11 on older Linux and portals on newer Wayland.
whisper_libei_prefix="${1:?libei install prefix is required}"
whisper_libei_version=1.3.0
whisper_libei_sha256=162dc7b0d86a4575cdde1d3cb04f364f89a8b1ba6d95fe0b442564e0444d851d
whisper_libei_work="$(mktemp -d)"
trap 'rm -rf "$whisper_libei_work"' EXIT
curl --fail --location --retry 3 \
  "https://gitlab.freedesktop.org/libinput/libei/-/archive/${whisper_libei_version}/libei-${whisper_libei_version}.tar.gz" \
  --output "$whisper_libei_work/libei.tar.gz"
echo "$whisper_libei_sha256  $whisper_libei_work/libei.tar.gz" | sha256sum --check --status
tar -xzf "$whisper_libei_work/libei.tar.gz" -C "$whisper_libei_work"
meson setup "$whisper_libei_work/build" "$whisper_libei_work/libei-$whisper_libei_version" \
  --prefix="$whisper_libei_prefix" --libdir=lib --buildtype=release \
  -Dtests=disabled -Dliboeffis=disabled
meson compile -C "$whisper_libei_work/build"
meson install -C "$whisper_libei_work/build"
install -Dm644 "$whisper_libei_work/libei-$whisper_libei_version/COPYING" \
  "$whisper_libei_prefix/share/licenses/libei/COPYING"

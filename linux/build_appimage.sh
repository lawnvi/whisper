#!/bin/bash

set -euo pipefail

VERSION="${1:?version is required}"
APP_NAME="whisper"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${PROJECT_DIR}/build/linux/appimage"
APPDIR="${OUTPUT_DIR}/${APP_NAME}.AppDir"
BUNDLE_DIR="${PROJECT_DIR}/build/linux/x64/release/bundle"
LIB_DIR="${APPDIR}/usr/bin/lib"
FALLBACK_DIR="${LIB_DIR}/fallback"
SYSTEM_LIB_DIR="${SYSTEM_LIB_DIR:-/usr/lib/x86_64-linux-gnu}"

# Linked by the app and missing on many desktops: global shortcuts, the tray
# icon (the first five) and stored keys. They only talk to GTK, X11 and
# D-Bus, so the build machine's copies also work on newer systems.
BUNDLED_LIBS=(
  libkeybinder-3.0.so.0
  libayatana-appindicator3.so.1
  libayatana-indicator3.so.7
  libayatana-ido3-0.4.so.0
  libdbusmenu-glib.so.4
  libdbusmenu-gtk3.so.4
  libsecret-1.so.0
)

# GStreamer plays audio. Its plugins come from the system and only work with
# the system's own GStreamer, so AppRun uses these copies only where there is
# none: the app then starts, without sound.
FALLBACK_LIBS=(
  libgstreamer-1.0.so.0
  libgstbase-1.0.so.0
  libgstapp-1.0.so.0
  libunwind.so.8
  libdw.so.1
)

# What the AppImage takes from the system it runs on: glibc and the C++
# runtime, GTK 3 and what it is built on, X11, the PulseAudio client and a
# few libraries that all of these pull in. Anything else the app links has
# to be bundled, or the build stops: without it the app would not start.
SYSTEM_LIBS=(
  ld-linux-x86-64.so.2 libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0
  librt.so.1 libgcc_s.so.1 libstdc++.so.6
  libglib-2.0.so.0 libgobject-2.0.so.0 libgio-2.0.so.0 libgmodule-2.0.so.0
  libgtk-3.so.0 libgdk-3.so.0 libgdk_pixbuf-2.0.so.0 libatk-1.0.so.0
  libpango-1.0.so.0 libpangocairo-1.0.so.0 libcairo.so.2
  libcairo-gobject.so.2 libharfbuzz.so.0 libfontconfig.so.1 libepoxy.so.0
  libX11.so.6 libXi.so.6 libXrandr.so.2 libXtst.so.6
  # GTK 3 links it for its Wayland backend; window flow speaks KWin's
  # protocols through it.
  libwayland-client.so.0
  libpulse.so.0 libpulse-simple.so.0
  libgcrypt.so.20 libelf.so.1 libz.so.1 liblzma.so.5 libbz2.so.1.0
  libzstd.so.1
  # Asked for by the JNI bridge, which nothing loads on the desktop.
  libjvm.so
)

dart "${PROJECT_DIR}/script/prune_flutter_assets.dart" linux-x64 \
  "${BUNDLE_DIR}/data/flutter_assets"

rm -rf "${APPDIR}"
mkdir -p "${APPDIR}/usr/bin"
mkdir -p "${APPDIR}/usr/share/applications"
mkdir -p "${APPDIR}/usr/share/icons/hicolor/256x256/apps"

cp -R "${BUNDLE_DIR}/." "${APPDIR}/usr/bin"
cp "${PROJECT_DIR}/linux/app_icon.png" "${APPDIR}/${APP_NAME}.png"
cp "${PROJECT_DIR}/linux/app_icon.png" "${APPDIR}/usr/share/icons/hicolor/256x256/apps/${APP_NAME}.png"

bundle_libs() { # bundle_libs <directory> <library>...
  local target="$1" lib
  shift
  mkdir -p "${target}"
  for lib in "$@"; do
    if [[ ! -e "${SYSTEM_LIB_DIR}/${lib}" ]]; then
      echo "${SYSTEM_LIB_DIR}/${lib} is missing; install its package" >&2
      exit 1
    fi
    cp -L "${SYSTEM_LIB_DIR}/${lib}" "${target}/${lib}"
    patchelf --set-rpath '$ORIGIN' "${target}/${lib}"
  done
}

bundle_libs "${LIB_DIR}" "${BUNDLED_LIBS[@]}"
bundle_libs "${FALLBACK_DIR}" "${FALLBACK_LIBS[@]}"

needed_libs() {
  readelf -d "$1" | sed -n 's/.*(NEEDED).*\[\(.*\)\]$/\1/p'
}

# Flutter leaves the plugins looking for libraries in the build machine's
# ephemeral folder. Point them next to themselves, where the bundled
# libraries are; a library only searches its own path, not the app's.
for lib in "${LIB_DIR}"/*.so*; do
  if readelf -d "${lib}" | grep -qE '\((RUNPATH|RPATH)\)' &&
    ! readelf -d "${lib}" | grep -qE '\((RUNPATH|RPATH)\).*\[\$ORIGIN\]$'; then
    patchelf --set-rpath '$ORIGIN' "${lib}"
  fi
done

unresolved=0
while IFS= read -r -d '' file; do
  readelf -h "${file}" >/dev/null 2>&1 || continue
  while IFS= read -r lib; do
    [[ -e "${LIB_DIR}/${lib}" || -e "${FALLBACK_DIR}/${lib}" ]] && continue
    printf '%s\n' "${SYSTEM_LIBS[@]}" | grep -qxF "${lib}" && continue
    echo "${file#"${APPDIR}/"} needs ${lib}, which is neither bundled" \
      "nor one of the system libraries" >&2
    unresolved=1
  done < <(needed_libs "${file}")
done < <(find "${APPDIR}" -type f -print0)
if (( unresolved )); then
  exit 1
fi

cat > "${APPDIR}/${APP_NAME}.desktop" <<EOF
[Desktop Entry]
Name=Whisper
Comment=Cross-platform local network file and message transfer
Exec=${APP_NAME}
Icon=${APP_NAME}
Terminal=false
Type=Application
Categories=Utility;Network;
StartupWMClass=whisper
MimeType=application/octet-stream;application/pdf;application/zip;text/plain;image/png;image/jpeg;audio/mpeg;video/mp4;
Actions=QuickSend;

[Desktop Action QuickSend]
Name=Send with Whisper
Exec=${APP_NAME} --quick-send %F
EOF

cp "${APPDIR}/${APP_NAME}.desktop" "${APPDIR}/usr/share/applications/${APP_NAME}.desktop"

cat > "${APPDIR}/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"

has_system_lib() {
  PATH="${PATH}:/sbin:/usr/sbin" ldconfig -p 2>/dev/null |
    grep -qF "$1 (libc6,x86-64)" && return 0
  for dir in /usr/lib/x86_64-linux-gnu /usr/lib64 /usr/lib; do
    [ -e "${dir}/$1" ] && return 0
  done
  return 1
}

# The bundled GStreamer only stands in where the system has none.
if ! has_system_lib libgstreamer-1.0.so.0 ||
  ! has_system_lib libgstapp-1.0.so.0; then
  export LD_LIBRARY_PATH="${HERE}/usr/bin/lib/fallback${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
fi

exec "${HERE}/usr/bin/whisper" "$@"
EOF

chmod +x "${APPDIR}/AppRun"

mkdir -p "${OUTPUT_DIR}"
APPIMAGE_TOOL="${APPIMAGE_TOOL:-appimagetool}"
TOOL_ARGS=()
if [[ -n "${APPIMAGE_RUNTIME_FILE:-}" ]]; then
  TOOL_ARGS+=(--runtime-file "${APPIMAGE_RUNTIME_FILE}")
fi
# The tool is an AppImage itself; unpacking it spares the build FUSE.
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "${APPIMAGE_TOOL}" "${TOOL_ARGS[@]}" \
  "${APPDIR}" "${OUTPUT_DIR}/whisper-${VERSION}-x86_64.AppImage"

echo "Created ${OUTPUT_DIR}/whisper-${VERSION}-x86_64.AppImage"

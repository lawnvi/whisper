#!/bin/bash

set -euo pipefail

VERSION="${1:?version is required}"
APP_NAME="whisper"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${PROJECT_DIR}/build/linux/appimage"
APPDIR="${OUTPUT_DIR}/${APP_NAME}.AppDir"
BUNDLE_DIR="${PROJECT_DIR}/build/linux/x64/release/bundle"

rm -rf "${APPDIR}"
mkdir -p "${APPDIR}/usr/bin"
mkdir -p "${APPDIR}/usr/share/applications"
mkdir -p "${APPDIR}/usr/share/icons/hicolor/256x256/apps"

cp -R "${BUNDLE_DIR}/." "${APPDIR}/usr/bin"
cp "${PROJECT_DIR}/linux/app_icon.png" "${APPDIR}/${APP_NAME}.png"
cp "${PROJECT_DIR}/linux/app_icon.png" "${APPDIR}/usr/share/icons/hicolor/256x256/apps/${APP_NAME}.png"

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
EOF

cp "${APPDIR}/${APP_NAME}.desktop" "${APPDIR}/usr/share/applications/${APP_NAME}.desktop"

cat > "${APPDIR}/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "${HERE}/usr/bin/whisper" "$@"
EOF

chmod +x "${APPDIR}/AppRun"

mkdir -p "${OUTPUT_DIR}"
APPIMAGE_TOOL="${APPIMAGE_TOOL:-appimagetool}"
"${APPIMAGE_TOOL}" "${APPDIR}" "${OUTPUT_DIR}/whisper-${VERSION}-x86_64.AppImage"

echo "Created ${OUTPUT_DIR}/whisper-${VERSION}-x86_64.AppImage"

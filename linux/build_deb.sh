#!/bin/bash

set -euo pipefail

VERSION="${1:?version is required}"
ARCHITECTURE="${2:-amd64}"
APP_NAME="whisper"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${PROJECT_DIR}/build/linux/deb"
BUILD_DIR="${OUTPUT_DIR}/pkgroot"
INSTALL_DIR="/opt/${APP_NAME}"
BUNDLE_DIR="${PROJECT_DIR}/build/linux/x64/release/bundle"

echo "Building DEB package ${APP_NAME} ${VERSION} (${ARCHITECTURE})"

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}/DEBIAN"
mkdir -p "${BUILD_DIR}${INSTALL_DIR}"
mkdir -p "${BUILD_DIR}/usr/share/applications"
mkdir -p "${BUILD_DIR}/usr/share/icons/hicolor/256x256/apps"

cp -R "${BUNDLE_DIR}/." "${BUILD_DIR}${INSTALL_DIR}"
cp "${PROJECT_DIR}/linux/app_icon.png" "${BUILD_DIR}/usr/share/icons/hicolor/256x256/apps/${APP_NAME}.png"

cat > "${BUILD_DIR}/DEBIAN/control" <<EOF
Package: ${APP_NAME}
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: ${ARCHITECTURE}
Maintainer: lawnvi
Homepage: https://github.com/lawnvi/whisper
Description: Cross-platform local network file and message transfer
EOF

cat > "${BUILD_DIR}/usr/share/applications/${APP_NAME}.desktop" <<EOF
[Desktop Entry]
Name=Whisper
Comment=Cross-platform local network file and message transfer
Exec=${INSTALL_DIR}/${APP_NAME}
Icon=${APP_NAME}
Terminal=false
Type=Application
Categories=Utility;Network;
StartupWMClass=whisper
EOF

cat > "${BUILD_DIR}/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
update-desktop-database >/dev/null 2>&1 || true
gtk-update-icon-cache /usr/share/icons/hicolor >/dev/null 2>&1 || true
EOF

cat > "${BUILD_DIR}/DEBIAN/postrm" <<EOF
#!/bin/sh
set -e
update-desktop-database >/dev/null 2>&1 || true
gtk-update-icon-cache /usr/share/icons/hicolor >/dev/null 2>&1 || true
EOF

chmod 0755 "${BUILD_DIR}/DEBIAN/postinst" "${BUILD_DIR}/DEBIAN/postrm"

mkdir -p "${OUTPUT_DIR}"
dpkg-deb --build "${BUILD_DIR}" "${OUTPUT_DIR}/${APP_NAME}-${ARCHITECTURE}.deb"

echo "Created ${OUTPUT_DIR}/${APP_NAME}-${ARCHITECTURE}.deb"

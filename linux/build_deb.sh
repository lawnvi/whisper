#!/bin/bash

# 定义版本和架构
VERSION=$1
ARCHITECTURE=$2

echo "build deb version: ${VERSION}"

# 定义你的Flutter项目的根目录
FLUTTER_PROJECT_DIR="."

# 定义你想要放置.deb文件的目录
OUTPUT_DIR="${FLUTTER_PROJECT_DIR}/build/linux/deb"

# 定义临时构建目录
BUILD_DIR="${OUTPUT_DIR}/build"

# 清理旧的构建目录
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# 编译Flutter项目为Linux应用程序
cd "${FLUTTER_PROJECT_DIR}"
flutter build linux

# 创建DEBIAN控制文件所需的目录结构
DEBIAN_DIR="${BUILD_DIR}/DEBIAN"
mkdir -p "${DEBIAN_DIR}"

# 创建控制文件
CONTROL_FILE="${DEBIAN_DIR}/control"
APPLICATION_NAME="whisper" # 修改为你的应用名称
cat > "${CONTROL_FILE}" <<EOF
Package: ${APPLICATION_NAME}
Version: ${VERSION}
Section: base
Priority: optional
Architecture: ${ARCHITECTURE}
Depends: libc6 (>= 2.28), libgcc1 (>= 1:3.0), libstdc++6 (>= 5.2)
Maintainer: Your Name <youremail@example.com>
Description: Your application description
EOF

# 创建桌面条目文件夹
DESKTOP_ENTRIES_DIR="${BUILD_DIR}/usr/share/applications"
mkdir -p "${DESKTOP_ENTRIES_DIR}"

# 创建.desktop文件
DESKTOP_FILE="${DESKTOP_ENTRIES_DIR}/${APPLICATION_NAME}.desktop"
cat > "${DESKTOP_FILE}" <<EOF
[Desktop Entry]
Name=${APPLICATION_NAME}
Comment=Your application description
Exec=/usr/local/bin/${APPLICATION_NAME}/${APPLICATION_NAME}
Icon=app_icon.png
Terminal=false
Type=Application
Categories=Utility;
EOF

# 如果有图标，也应该复制到相应的目录
# 假设你的图标位于项目的icons目录下
ICON_DIR="${BUILD_DIR}/usr/share/icons/hicolor/scalable/apps"
mkdir -p "${ICON_DIR}"
cp "${FLUTTER_PROJECT_DIR}/linux/app_icon.png" "${ICON_DIR}"

# 复制编译后的文件到构建目录
APPLICATION_DIR="${BUILD_DIR}/usr/local/bin/${APPLICATION_NAME}"
mkdir -p "${APPLICATION_DIR}"
cp -r "${FLUTTER_PROJECT_DIR}/build/linux/x64/release/bundle/." "${APPLICATION_DIR}"

# 创建.deb包
DEB_PACKAGE_NAME="${APPLICATION_NAME}_${VERSION}_${ARCHITECTURE}.deb"
dpkg-deb --build "${BUILD_DIR}" "${OUTPUT_DIR}/${DEB_PACKAGE_NAME}"

echo "Deb package created at: ${OUTPUT_DIR}/${DEB_PACKAGE_NAME}"


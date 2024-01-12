#!/bin/bash

# deprecated // use alien instead

# 定义版本和发布号
VERSION=$1
RELEASE="1"
ARCHITECTURE=$2

# 定义Flutter项目的根目录
FLUTTER_PROJECT_DIR="."
APPLICATION_NAME="whisper" # 修改为你的应用名称

# 安装rpmdevtools和rpmbuild（如果尚未安装）
sudo dnf install rpmdevtools rpmbuild -y

# 设置rpmbuild环境
rpmdev-setuptree

# 编译Flutter项目为Linux应用程序
cd "${FLUTTER_PROJECT_DIR}"
flutter build linux --release

# 创建RPM构建目录中的源码包目录
SOURCES_DIR="$HOME/rpmbuild/SOURCES"
mkdir -p "${SOURCES_DIR}/${APPLICATION_NAME}-${VERSION}"
cp -r "${FLUTTER_PROJECT_DIR}/build/linux/x64/release/bundle/"* "${SOURCES_DIR}/${APPLICATION_NAME}-${VERSION}"

# 创建.tar.gz源码包
tar czf "${SOURCES_DIR}/${APPLICATION_NAME}-${VERSION}.tar.gz" -C "${SOURCES_DIR}" "${APPLICATION_NAME}-${VERSION}"

# 创建SPEC文件
SPEC_FILE="$HOME/rpmbuild/SPECS/${APPLICATION_NAME}.spec"
cat > "${SPEC_FILE}" <<EOF
Name:           ${APPLICATION_NAME}
Version:        ${VERSION}
Release:        ${RELEASE}%{?dist}
Summary:        Your application description

License:        Your License
URL:            Your URL
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  gtk3-devel
Requires:       libc6, libgcc1, libstdc++6

%description
Your application description.

%prep
%autosetup

%build
# 如果需要构建步骤，请在这里添加

%install
mkdir -p %{buildroot}/usr/local/bin/%{name}
cp -r * %{buildroot}/usr/local/bin/%{name}

# 创建桌面条目
mkdir -p %{buildroot}/usr/share/applications
cat > %{buildroot}/usr/share/applications/%{name}.desktop <<EOF2
[Desktop Entry]
Name=%{name}
Comment=whisper with u
Exec=/usr/local/bin/%{name}/%{name}
Icon=app_icon.png
Terminal=false
Type=Application
Categories=Utility;
EOF2

# 如果有图标，也应该安装到相应的目录
# mkdir -p %{buildroot}/usr/share/icons/hicolor/scalable/apps
# cp %{_sourcedir}/linux/app_icon.png %{buildroot}/usr/share/icons/hicolor/scalable/apps

%files
/usr/local/bin/%{name}
/usr/share/applications/%{name}.desktop
# /usr/share/icons/hicolor/scalable/apps/%{name}.svg

%changelog
* Day Mon DD YYYY Your Name <youremail@example.com> - %{version}-%{release}
- First build of %{name}
EOF

# 构建RPM包
rpmbuild -ba "${SPEC_FILE}"

echo "RPM package created."

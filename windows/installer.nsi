!include "MUI2.nsh"
!include "FileFunc.nsh"

!ifndef APP_NAME
  !define APP_NAME "Whisper"
!endif

!ifndef APP_VERSION
  !define APP_VERSION "0.0.0"
!endif

!ifndef APP_PUBLISHER
  !define APP_PUBLISHER "lawnvi"
!endif

!ifndef APP_EXE
  !define APP_EXE "whisper.exe"
!endif

!ifndef INSTALL_ROOT
  !define INSTALL_ROOT "$LocalAppData\Programs\${APP_NAME}"
!endif

!ifndef OUTPUT_NAME
  !define OUTPUT_NAME "whisper-windows-x86_64.exe"
!endif

Name "${APP_NAME}"
OutFile "${OUTPUT_NAME}"
InstallDir "${INSTALL_ROOT}"
InstallDirRegKey HKCU "Software\${APP_NAME}" "InstallDir"
RequestExecutionLevel user

VIProductVersion "${APP_VERSION}.0"
VIAddVersionKey "ProductName" "${APP_NAME}"
VIAddVersionKey "CompanyName" "${APP_PUBLISHER}"
VIAddVersionKey "FileVersion" "${APP_VERSION}"
VIAddVersionKey "ProductVersion" "${APP_VERSION}"
VIAddVersionKey "FileDescription" "${APP_NAME} installer"

!define MUI_ABORTWARNING
!define MUI_ICON "${EXDIR}\runner\resources\app_icon.ico"
!define MUI_UNICON "${EXDIR}\runner\resources\app_icon.ico"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

Section "Install"
  SetOutPath "$INSTDIR"
  File /r "${EXDIR}\..\build\windows\x64\runner\Release\*.*"

  CreateDirectory "$SMPROGRAMS\${APP_NAME}"
  CreateShortcut "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}"
  CreateShortcut "$DESKTOP\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}"

  WriteRegStr HKCU "Software\${APP_NAME}" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "DisplayName" "${APP_NAME}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "Publisher" "${APP_PUBLISHER}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "DisplayIcon" "$INSTDIR\${APP_EXE}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "UninstallString" "$INSTDIR\Uninstall.exe"
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "NoRepair" 1

  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "EstimatedSize" "$0"

  WriteUninstaller "$INSTDIR\Uninstall.exe"
SectionEnd

Section "Uninstall"
  Delete "$DESKTOP\${APP_NAME}.lnk"
  Delete "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk"
  RMDir "$SMPROGRAMS\${APP_NAME}"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir /r "$INSTDIR"
  DeleteRegKey HKCU "Software\${APP_NAME}"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}"
SectionEnd

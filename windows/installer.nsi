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

!ifndef BUILD_DIR
  !define BUILD_DIR "..\build\windows\x64\runner\Release"
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
!define MUI_ICON "runner\resources\app_icon.ico"
!define MUI_UNICON "runner\resources\app_icon.ico"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

Section "Install"
  ; Updating from inside Whisper leaves the running executable locked on Windows.
  ; The user has already confirmed installation before this section begins.
  nsExec::ExecToLog 'taskkill /IM "${APP_EXE}" /F'
  Pop $0

  SetOutPath "$INSTDIR"
  File /r "${BUILD_DIR}\*.*"

  CreateDirectory "$SMPROGRAMS\${APP_NAME}"
  CreateShortcut "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}"
  CreateShortcut "$SMPROGRAMS\${APP_NAME}\${APP_NAME} Quick Send.lnk" "$INSTDIR\${APP_EXE}" "--quick-send" "$INSTDIR\${APP_EXE}" 0 SW_SHOWNORMAL CONTROL|ALT|V "Send clipboard with ${APP_NAME}"
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

  WriteRegStr HKCU "Software\Classes\*\shell\Whisper.Send" "MUIVerb" "Send with Whisper"
  WriteRegStr HKCU "Software\Classes\*\shell\Whisper.Send" "Icon" "$INSTDIR\${APP_EXE}"
  WriteRegStr HKCU "Software\Classes\*\shell\Whisper.Send" "MultiSelectModel" "Document"
  WriteRegStr HKCU "Software\Classes\*\shell\Whisper.Send\command" "" '$\"$INSTDIR\${APP_EXE}$\" --quick-send-file $\"%1$\"'
  DeleteRegKey HKCU "Software\Classes\Directory\shell\Whisper.Send"

  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "EstimatedSize" "$0"

  WriteUninstaller "$INSTDIR\Uninstall.exe"
SectionEnd

Section "Uninstall"
  Delete "$DESKTOP\${APP_NAME}.lnk"
  Delete "$SMPROGRAMS\${APP_NAME}\${APP_NAME} Quick Send.lnk"
  Delete "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk"
  RMDir "$SMPROGRAMS\${APP_NAME}"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir /r "$INSTDIR"
  DeleteRegKey HKCU "Software\${APP_NAME}"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}"
  DeleteRegKey HKCU "Software\Classes\*\shell\Whisper.Send"
  DeleteRegKey HKCU "Software\Classes\Directory\shell\Whisper.Send"
SectionEnd

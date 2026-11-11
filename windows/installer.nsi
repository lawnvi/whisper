!include "MUI2.nsh"
!include "FileFunc.nsh"
!include "LogicLib.nsh"

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

!ifndef INPUT_SERVICE_NAME
  !define INPUT_SERVICE_NAME "WhisperInputService"
!endif

!ifndef INPUT_SERVICE_OPT_OUT
  !define INPUT_SERVICE_OPT_OUT "InputServiceOptOut"
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

; Whisper updates itself by running this installer with /UPDATE. There is
; nothing to ask then: it goes where Whisper already is, shows only its
; progress, and starts Whisper again when it is done.
Var Updating

!define MUI_PAGE_CUSTOMFUNCTION_PRE SkipWhenUpdating
!insertmacro MUI_PAGE_WELCOME
!define MUI_PAGE_CUSTOMFUNCTION_PRE SkipWhenUpdating
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!define MUI_PAGE_CUSTOMFUNCTION_PRE SkipWhenUpdating
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

Function .onInit
  StrCpy $Updating "0"
  ${GetParameters} $R0
  ClearErrors
  ${GetOptions} $R0 "/UPDATE" $R1
  ${IfNot} ${Errors}
    StrCpy $Updating "1"
  ${EndIf}
FunctionEnd

Function SkipWhenUpdating
  ${If} $Updating == "1"
    Abort
  ${EndIf}
FunctionEnd

Function .onInstSuccess
  ${If} $Updating == "1"
    Exec '"$INSTDIR\${APP_EXE}"'
  ${EndIf}
FunctionEnd

Section "Install"
  ${If} $Updating == "1"
    SetAutoClose true
    ; Whisper is closing by itself: give it about five seconds (a look takes
    ; a moment too), so that it is not killed in the middle of saving what it
    ; was doing.
    StrCpy $1 0
    ${Do}
      nsExec::Exec 'cmd /c tasklist /FI "IMAGENAME eq ${APP_EXE}" /NH | find /I "${APP_EXE}"'
      Pop $0
      ${If} $0 != 0
        ${ExitDo}
      ${EndIf}
      Sleep 250
      IntOp $1 $1 + 1
    ${LoopUntil} $1 >= 10
  ${EndIf}

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

  ; The lock screen input service comes with the app and is brought up to date
  ; on every upgrade, which takes one elevation prompt. Whoever removed it from
  ; the app's settings is not asked again.
  ReadRegDWORD $0 HKCU "Software\${APP_NAME}" "${INPUT_SERVICE_OPT_OUT}"
  StrCmp $0 "1" input_service_installed
  ; An update only brings a service that is there up to date; whoever never
  ; let it be installed is not asked again every time.
  ${If} $Updating == "1"
    ReadRegStr $0 HKLM "SYSTEM\CurrentControlSet\Services\${INPUT_SERVICE_NAME}" "ImagePath"
    StrCmp $0 "" input_service_installed
  ${EndIf}
  DetailPrint "Installing the lock screen input service (administrator approval required)..."
  ExecShellWait "runas" "$INSTDIR\${APP_EXE}" "--install-input-service" SW_HIDE
  input_service_installed:
SectionEnd

Section "Uninstall"
  ; The optional lock screen input service is installed machine-wide from
  ; inside the app, so removing it needs one elevation prompt of its own.
  ReadRegStr $0 HKLM "SYSTEM\CurrentControlSet\Services\${INPUT_SERVICE_NAME}" "ImagePath"
  StrCmp $0 "" input_service_removed
  ExecShellWait "runas" "$INSTDIR\${APP_EXE}" "--uninstall-input-service" SW_HIDE
  input_service_removed:

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

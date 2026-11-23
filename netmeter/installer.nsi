; NetMeter Setup.exe (NSIS 3, per-user, no admin rights).
; Build:  powershell -ExecutionPolicy Bypass -File netmeter\build.ps1
; or:     makensis /DAPP_VERSION=0.1.0 netmeter\installer.nsi
;
; The installer UI is Persian (built-in NSIS Farsi language), everything else
; stays ASCII so the script is encoding-safe.

Unicode true

!define APP_NAME "NetMeter"
!define APP_EXE "NetMeter.exe"
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\NetMeter"
!ifndef APP_VERSION
  !define APP_VERSION "0.1.0"
!endif

Name "${APP_NAME}"
OutFile "dist\NetMeter-Setup-${APP_VERSION}.exe"
InstallDir "$LOCALAPPDATA\NetMeter"
InstallDirRegKey HKCU "Software\NetMeter" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma
ShowInstDetails show
ShowUninstDetails show
BrandingText "NetMeter"

VIProductVersion "${APP_VERSION}.0"
VIAddVersionKey "ProductName" "NetMeter"
VIAddVersionKey "FileDescription" "NetMeter setup"
VIAddVersionKey "FileVersion" "${APP_VERSION}"
VIAddVersionKey "ProductVersion" "${APP_VERSION}"
VIAddVersionKey "LegalCopyright" "GPL-2.0-or-later"

!include "MUI2.nsh"
!include "FileFunc.nsh"

!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\${APP_EXE}"
!define MUI_FINISHPAGE_RUN_PARAMETERS "--no-browser"
!define MUI_FINISHPAGE_RUN_TEXT "Run NetMeter"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "Farsi"
!insertmacro MUI_LANGUAGE "English"

; ---------------------------------------------------------------------------
Section "NetMeter" SEC_MAIN
  SectionIn RO
  SetOutPath "$INSTDIR"
  File /r "dist\NetMeter\*.*"
  CreateDirectory "$INSTDIR\data"

  CreateShortCut "$DESKTOP\NetMeter.lnk" "$INSTDIR\${APP_EXE}" \
    "--no-browser --data-dir $\"$INSTDIR\data$\"" "$INSTDIR\${APP_EXE}" 0
  CreateDirectory "$SMPROGRAMS\NetMeter"
  CreateShortCut "$SMPROGRAMS\NetMeter\NetMeter.lnk" "$INSTDIR\${APP_EXE}" \
    "--no-browser --data-dir $\"$INSTDIR\data$\"" "$INSTDIR\${APP_EXE}" 0
  CreateShortCut "$SMPROGRAMS\NetMeter\Uninstall NetMeter.lnk" "$INSTDIR\Uninstall.exe"

  WriteUninstaller "$INSTDIR\Uninstall.exe"

  WriteRegStr HKCU "Software\NetMeter" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayName" "NetMeter"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "${UNINST_KEY}" "Publisher" "NetMeter"
  WriteRegStr HKCU "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\${APP_EXE}"
  WriteRegStr HKCU "${UNINST_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "${UNINST_KEY}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKCU "${UNINST_KEY}" "EstimatedSize" "$0"
SectionEnd

Section /o "Start with Windows" SEC_AUTO
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "NetMeter" \
    '"$INSTDIR\${APP_EXE}" --no-browser --data-dir "$INSTDIR\data"'
SectionEnd

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SEC_MAIN} "Installs NetMeter and creates shortcuts."
  !insertmacro MUI_DESCRIPTION_TEXT ${SEC_AUTO} "Starts NetMeter automatically when you sign in."
!insertmacro MUI_FUNCTION_DESCRIPTION_END

; ---------------------------------------------------------------------------
Section "Uninstall"
  nsExec::Exec 'taskkill /F /IM ${APP_EXE}'

  Delete "$DESKTOP\NetMeter.lnk"
  Delete "$SMPROGRAMS\NetMeter\NetMeter.lnk"
  Delete "$SMPROGRAMS\NetMeter\Uninstall NetMeter.lnk"
  RMDir "$SMPROGRAMS\NetMeter"

  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "NetMeter"
  DeleteRegKey HKCU "${UNINST_KEY}"
  DeleteRegKey HKCU "Software\NetMeter"

  RMDir /r "$INSTDIR\_internal"
  RMDir /r "$INSTDIR\web"
  Delete "$INSTDIR\${APP_EXE}"
  Delete "$INSTDIR\README.md"
  Delete "$INSTDIR\NOTICE"
  Delete "$INSTDIR\LICENSE"
  Delete "$INSTDIR\Uninstall.exe"

  IfFileExists "$INSTDIR\data\*.*" keep_data
  RMDir "$INSTDIR"
  Goto uninstall_done
keep_data:
  IfSilent uninstall_done
  MessageBox MB_OK "NetMeter was removed. Saved usage history in $INSTDIR\data was kept."
uninstall_done:
SectionEnd

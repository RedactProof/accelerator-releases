; RedactProof Accelerator - unsigned NSIS installer
; Per-user install, no admin required, autostart via HKCU\Run.
;
; Install order is intentional:
;   1. Validate host arch matches bundle - abort with friendly message if not.
;   2. Write the Uninstall.exe binary.
;   3. Write the Add/Remove Programs registry block - so even if a later step
;      fails, the user always has a working Uninstall path.
;   4. Extract the payload (the most likely failure point) with IfErrors.
;   5. Create launcher .vbs, autostart entry, start-menu shortcut.
;   6. Launch the bridge.

!define APP_NAME "RedactProof Accelerator"
; APP_VERSION is passed in via /DAPP_VERSION=x.y.z from build.ps1
!ifndef APP_VERSION
  !define APP_VERSION "0.0.0"
!endif
!define APP_PUBLISHER "Popsall Ltd"
!define APP_URL "https://redactproof.com"
!define APP_EXE "node.exe"
!define APP_ID "RedactProofAccelerator"
!define ARP_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_ID}"
!define RUN_KEY "Software\Microsoft\Windows\CurrentVersion\Run"

; ARCH passed via /DARCH=x64 or /DARCH=arm64
!ifndef ARCH
  !define ARCH "x64"
!endif

Unicode true
SetCompressor /SOLID lzma
RequestExecutionLevel user

Name "${APP_NAME}"
OutFile "..\dist\RedactProof-Accelerator-Setup-${ARCH}-${APP_VERSION}.exe"
InstallDir "$LOCALAPPDATA\RedactProof\Accelerator"
InstallDirRegKey HKCU "Software\${APP_ID}" "InstallDir"
ShowInstDetails show
ShowUninstDetails show

!include "MUI2.nsh"
!include "x64.nsh"
!include "LogicLib.nsh"

!define MUI_ABORTWARNING
!define MUI_ICON "assets\app.ico"
!define MUI_UNICON "assets\app.ico"
!define MUI_HEADERIMAGE
!define MUI_HEADERIMAGE_BITMAP "assets\header.bmp"
!define MUI_HEADERIMAGE_UNBITMAP "assets\header.bmp"
!define MUI_WELCOMEFINISHPAGE_BITMAP "assets\welcome.bmp"
!define MUI_UNWELCOMEFINISHPAGE_BITMAP "assets\welcome.bmp"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

VIProductVersion "${APP_VERSION}.0"
VIAddVersionKey "ProductName" "${APP_NAME}"
VIAddVersionKey "CompanyName" "${APP_PUBLISHER}"
VIAddVersionKey "FileVersion" "${APP_VERSION}"
VIAddVersionKey "ProductVersion" "${APP_VERSION}"
VIAddVersionKey "FileDescription" "Local PII detection helper for RedactProof"
VIAddVersionKey "LegalCopyright" "(c) Popsall Ltd"

; ----- Arch validation -----
; Stop the user installing the wrong-arch build. The bundled onnxruntime-node
; native binary is arch-specific; running x64 on ARM64 (or vice versa) produces
; a half-installed app that crashes at startup with no clear error.
Function .onInit
  ${If} "${ARCH}" == "arm64"
    ${IfNot} ${IsNativeARM64}
      MessageBox MB_ICONSTOP "This is the ARM64 build of ${APP_NAME}, but this PC is not ARM64.$\r$\n$\r$\nDownload the x64 installer from ${APP_URL} instead."
      Abort
    ${EndIf}
  ${ElseIf} "${ARCH}" == "x64"
    ${If} ${IsNativeARM64}
      MessageBox MB_ICONSTOP "This is the x64 build of ${APP_NAME}, but this PC is ARM64.$\r$\n$\r$\nDownload the ARM64 installer from ${APP_URL} instead."
      Abort
    ${EndIf}
    ${IfNot} ${IsNativeAMD64}
      MessageBox MB_ICONSTOP "${APP_NAME} requires 64-bit Windows."
      Abort
    ${EndIf}
  ${EndIf}
FunctionEnd

Section "Install"
  SetOutPath "$INSTDIR"
  SetRegView default

  ; Stop any existing instance before overwriting files.
  nsExec::Exec 'cmd /c "if exist "$INSTDIR\bridge.pid" (for /f %i in ($INSTDIR\bridge.pid) do taskkill /F /PID %i)"'

  ; ===== Step 1: Write the uninstaller binary FIRST =====
  ; If anything later fails, the user still has a working Uninstall.exe and a
  ; matching ARP entry, so they can clean up via Settings -> Apps.
  WriteUninstaller "$INSTDIR\Uninstall.exe"

  ; Bundle the icon early so DisplayIcon below points at a real file even if
  ; the main payload extract fails.
  File "/oname=$INSTDIR\app.ico" "assets\app.ico"

  ; ===== Step 2: Write the Add/Remove Programs registry block =====
  WriteRegStr   HKCU "${ARP_KEY}" "DisplayName"          "${APP_NAME}"
  WriteRegStr   HKCU "${ARP_KEY}" "DisplayVersion"       "${APP_VERSION}"
  WriteRegStr   HKCU "${ARP_KEY}" "Publisher"            "${APP_PUBLISHER}"
  WriteRegStr   HKCU "${ARP_KEY}" "URLInfoAbout"         "${APP_URL}"
  WriteRegStr   HKCU "${ARP_KEY}" "InstallLocation"      "$INSTDIR"
  WriteRegStr   HKCU "${ARP_KEY}" "DisplayIcon"          "$INSTDIR\app.ico"
  WriteRegStr   HKCU "${ARP_KEY}" "UninstallString"      '"$INSTDIR\Uninstall.exe"'
  WriteRegStr   HKCU "${ARP_KEY}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKCU "${ARP_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${ARP_KEY}" "NoRepair" 1
  ; EstimatedSize so ARP shows a Size column. ~190 MB unpacked (KB units).
  WriteRegDWORD HKCU "${ARP_KEY}" "EstimatedSize" 194560

  WriteRegStr HKCU "Software\${APP_ID}" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\${APP_ID}" "Version"    "${APP_VERSION}"

  ; ===== Step 3: Extract the payload (most likely failure point) =====
  ClearErrors
  File /r "..\dist\payload-${ARCH}\*.*"
  IfErrors payload_failed

  ; ===== Step 4: Launcher scripts, autostart, shortcut =====
  ; .vbs — used by HKCU\Run autostart (not browser-launched, no job-object issue)
  FileOpen $0 "$INSTDIR\start-bridge.vbs" w
  FileWrite $0 'Set ws = CreateObject("WScript.Shell")$\r$\n'
  FileWrite $0 'ws.CurrentDirectory = "$INSTDIR"$\r$\n'
  FileWrite $0 'ws.Run """$INSTDIR\node.exe"" ""$INSTDIR\server.mjs""", 0, False$\r$\n'
  FileClose $0

  ; .ps1 — used by the redactproof:// URL scheme handler only.
  ; Start-Process breaks out of the browser Job Object that kills grandchild
  ; processes when wscript.exe exits, which is why the .vbs cannot be used here.
  ; IMPORTANT: $INSTDIR is a valid NSIS variable and expands correctly here.
  ; Do NOT use $dir or $MyInvocation — those are not NSIS variables and expand
  ; to empty string, producing a broken ps1 file.
  FileOpen $0 "$INSTDIR\start-bridge.ps1" w
  FileWrite $0 'Start-Process -FilePath "$INSTDIR\node.exe" -ArgumentList "`"$INSTDIR\server.mjs`"" -WorkingDirectory "$INSTDIR" -WindowStyle Hidden$\r$\n'
  FileClose $0

  WriteRegStr HKCU "${RUN_KEY}" "${APP_ID}" '"wscript.exe" "$INSTDIR\start-bridge.vbs"'

  CreateDirectory "$SMPROGRAMS\${APP_NAME}"
  CreateShortcut  "$SMPROGRAMS\${APP_NAME}\Uninstall.lnk" "$INSTDIR\Uninstall.exe"

  ; ===== Step 5: Register redactproof:// URL scheme =====
  WriteRegStr HKCU "Software\Classes\redactproof" "" "URL:RedactProof Accelerator"
  WriteRegStr HKCU "Software\Classes\redactproof" "URL Protocol" ""
  WriteRegStr HKCU "Software\Classes\redactproof\shell\open\command" "" 'powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File "$INSTDIR\start-bridge.ps1" "%1"'

  ; ===== Step 6: Launch immediately =====
  Exec '"wscript.exe" "$INSTDIR\start-bridge.vbs"'
  Return

  payload_failed:
    MessageBox MB_ICONSTOP "Install failed: payload could not be extracted.$\r$\n$\r$\nUse Settings -> Apps -> ${APP_NAME} -> Uninstall to clean up, then try again."
    Abort
SectionEnd

Section "Uninstall"
  SetRegView default

  ; Stop running bridge if any.
  nsExec::Exec 'cmd /c "if exist "$INSTDIR\bridge.pid" (for /f %i in ($INSTDIR\bridge.pid) do taskkill /F /PID %i)"'
  Sleep 500

  ; Remove autostart.
  DeleteRegValue HKCU "${RUN_KEY}" "${APP_ID}"

  ; Remove discovery file.
  Delete "$PROFILE\.redactproof\accelerator.json"

  ; Remove install dir (includes start-bridge.vbs, start-bridge.ps1, etc).
  RMDir /r "$INSTDIR"

  ; Start menu.
  Delete "$SMPROGRAMS\${APP_NAME}\Uninstall.lnk"
  RMDir  "$SMPROGRAMS\${APP_NAME}"

  ; Registry.
  DeleteRegKey HKCU "${ARP_KEY}"
  DeleteRegKey HKCU "Software\${APP_ID}"
  DeleteRegKey HKCU "Software\Classes\redactproof"
SectionEnd

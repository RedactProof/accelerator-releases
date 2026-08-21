; RedactProof Accelerator - unsigned NSIS installer
; Per-user install, no admin required, autostart via HKCU\Run.
;
; Install order is intentional:
;   1. Validate host arch matches bundle - abort with friendly message if not.
;   2. Write the Uninstall.exe binary.
;   3. Write the Add/Remove Programs registry block - so even if a later step
;      fails, the user always has a working Uninstall path.
;   4. Extract the payload (the most likely failure point) with IfErrors.
;   5. Autostart entry, scheduled task, URL scheme, start-menu shortcuts -
;      every launch path goes through the bundled LaunchAccelerator.exe stub.
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

  ; Stop any existing instance before overwriting files. Three layers, because
  ; the pid file alone proved unreliable (stale pid -> node.exe stays locked ->
  ; "Error opening file for writing: node.exe" mid-extract):
  ;   1. End the scheduled task so it can't relaunch mid-install.
  ;   2. Kill the pid recorded in bridge.pid (fast path).
  ;   3. Path-filtered kill of any node.exe running from $INSTDIR (catches a
  ;      stale/missing pid file without touching unrelated Node processes).
  nsExec::Exec 'schtasks /End /TN "${APP_ID}"'
  nsExec::Exec 'cmd /c "if exist "$INSTDIR\bridge.pid" (for /f "usebackq" %i in ("$INSTDIR\bridge.pid") do taskkill /F /PID %i)"'
  nsExec::Exec `powershell -NoProfile -Command "Get-Process node -ErrorAction SilentlyContinue | Where-Object { $$_.Path -eq '$INSTDIR\node.exe' } | Stop-Process -Force"`
  ; Give the OS a moment to release file handles before extraction.
  Sleep 800

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

  ; ===== Step 4: Autostart via the launcher stub =====
  ; LaunchAccelerator.exe --direct spawns node.exe hidden (ExecShell SW_HIDE)
  ; and is used by HKCU\Run autostart AND the scheduled task's action.
  ;
  ; This REPLACED start-bridge.vbs. The vbs (wscript.exe running a
  ; hidden-window script from AppData) is a catalogued attacker technique and
  ; Defender's ML flagged it as Trojan:Win32/Commando.A!ml (Severe) on a
  ; customer machine, 2026-08-21. Do not reintroduce wscript or hidden
  ; powershell wrappers on any launch path - the hidden-scripting-host
  ; pattern is what trips AV, regardless of what the script does.
  ;
  ; Upgrade hygiene: earlier builds (<=0.1.1) wrote the vbs; File /r doesn't
  ; remove stray files, so delete it explicitly or upgraded installs keep the
  ; flagged file on disk.
  Delete "$INSTDIR\start-bridge.vbs"

  WriteRegStr HKCU "${RUN_KEY}" "${APP_ID}" '"$INSTDIR\LaunchAccelerator.exe" --direct'

  CreateDirectory "$SMPROGRAMS\${APP_NAME}"
  CreateShortcut  "$SMPROGRAMS\${APP_NAME}\Uninstall.lnk" "$INSTDIR\Uninstall.exe"

  ; ===== Step 5: Register Windows Scheduled Task =====
  ; The task is the URL-scheme launch target. Running via Task Scheduler breaks
  ; the browser Job Object inheritance chain: schtasks.exe posts an RPC to the
  ; Scheduler service and exits immediately; the Scheduler launches the task
  ; under its own session, completely outside the browser's Job Object.
  ; Empty <Triggers/> means no automatic trigger — only schtasks /Run fires it.
  ; MultipleInstancesPolicy=IgnoreNew prevents duplicate bridges on double-click.
  ;
  ; NO encoding attribute on the XML declaration. NSIS FileWrite emits ANSI
  ; bytes with no BOM; declaring encoding="UTF-8" made schtasks reject the
  ; file outright:
  ;     ERROR: The task XML is malformed.
  ;     (1,40)::ERROR: unable to switch the encoding
  ; ExecToLog never checked the exit code, so the failure was silent: the
  ; task was NEVER created, the redactproof:// handler below pointed at a
  ; task that did not exist, and "Start Accelerator" did nothing on every
  ; Windows install. It only ever appeared to work because Step 7 launches
  ; the bridge directly right after installing. Omitting the attribute (or
  ; writing UTF-16LE with encoding="UTF-16") both import cleanly - verified
  ; against schtasks on Windows 11, 2026-08-14.
  FileOpen $0 "$INSTDIR\task.xml" w
  FileWrite $0 '<?xml version="1.0"?>$\r$\n'
  FileWrite $0 '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">$\r$\n'
  FileWrite $0 '  <RegistrationInfo><Description>RedactProof Accelerator bridge</Description></RegistrationInfo>$\r$\n'
  FileWrite $0 '  <Triggers/>$\r$\n'
  FileWrite $0 '  <Settings>$\r$\n'
  FileWrite $0 '    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>$\r$\n'
  FileWrite $0 '    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>$\r$\n'
  FileWrite $0 '    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>$\r$\n'
  FileWrite $0 '    <Hidden>true</Hidden>$\r$\n'
  FileWrite $0 '    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>$\r$\n'
  FileWrite $0 '  </Settings>$\r$\n'
  FileWrite $0 '  <Actions Context="Author">$\r$\n'
  FileWrite $0 '    <Exec>$\r$\n'
  FileWrite $0 '      <Command>$INSTDIR\LaunchAccelerator.exe</Command>$\r$\n'
  FileWrite $0 '      <Arguments>--direct</Arguments>$\r$\n'
  FileWrite $0 '    </Exec>$\r$\n'
  FileWrite $0 '  </Actions>$\r$\n'
  FileWrite $0 '</Task>$\r$\n'
  FileClose $0
  nsExec::ExecToLog 'schtasks /Create /XML "$INSTDIR\task.xml" /TN "${APP_ID}" /F'
  Pop $1   ; exit code — 0 on success
  Delete "$INSTDIR\task.xml"

  ; ===== Step 6: Register redactproof:// URL scheme =====
  ; The handler points at our own bundled LaunchAccelerator.exe rather than
  ; straight at schtasks.exe. Both start the bridge via the scheduled task
  ; (schtasks posts an RPC to the Scheduler service and exits, so the bridge
  ; runs outside the browser's Job Object and survives the tab closing) — but
  ; the browser's "wants to open this application" prompt names the TARGET
  ; executable. With schtasks as the target it read
  ;   "Open Task Scheduler Configuration Tool?"
  ; which is schtasks.exe's own Windows file description and reads like
  ; malware to anyone sensible. The stub carries FileDescription="RedactProof
  ; Accelerator", so the prompt names us.
  ;
  ; The stub also falls back to spawning node directly by itself when the
  ; task is missing, so a launch link can't be a dead end.
  WriteRegStr HKCU "Software\Classes\redactproof" "" "URL:RedactProof Accelerator"
  WriteRegStr HKCU "Software\Classes\redactproof" "URL Protocol" ""
  WriteRegStr HKCU "Software\Classes\redactproof\DefaultIcon" "" "$INSTDIR\app.ico"
  WriteRegStr HKCU "Software\Classes\redactproof\shell\open\command" "" '"$INSTDIR\LaunchAccelerator.exe"'
  ${If} $1 != 0
    DetailPrint "Scheduled task registration failed (code $1) - launcher will fall back to direct start"
  ${EndIf}

  ; Start-menu launch entry, so searching "RedactProof" offers a way to start
  ; the accelerator instead of only the uninstaller.
  CreateShortcut "$SMPROGRAMS\${APP_NAME}\Start ${APP_NAME}.lnk" "$INSTDIR\LaunchAccelerator.exe" "" "$INSTDIR\app.ico"

  ; ===== Step 7: Launch immediately =====
  Exec '"$INSTDIR\LaunchAccelerator.exe" --direct'
  Return

  payload_failed:
    MessageBox MB_ICONSTOP "Install failed: payload could not be extracted.$\r$\n$\r$\nUse Settings -> Apps -> ${APP_NAME} -> Uninstall to clean up, then try again."
    Abort
SectionEnd

Section "Uninstall"
  SetRegView default

  ; Stop running bridge if any (same three layers as install).
  nsExec::Exec 'schtasks /End /TN "${APP_ID}"'
  nsExec::Exec 'cmd /c "if exist "$INSTDIR\bridge.pid" (for /f "usebackq" %i in ("$INSTDIR\bridge.pid") do taskkill /F /PID %i)"'
  nsExec::Exec `powershell -NoProfile -Command "Get-Process node -ErrorAction SilentlyContinue | Where-Object { $$_.Path -eq '$INSTDIR\node.exe' } | Stop-Process -Force"`
  Sleep 800
  Sleep 500

  ; Remove autostart and scheduled task.
  DeleteRegValue HKCU "${RUN_KEY}" "${APP_ID}"
  nsExec::Exec 'schtasks.exe /Delete /TN "${APP_ID}" /F'

  ; Remove discovery file.
  Delete "$PROFILE\.redactproof\accelerator.json"

  ; Remove install dir (includes the launcher stub and any legacy
  ; start-bridge.vbs/.ps1 from older builds).
  RMDir /r "$INSTDIR"

  ; Start menu.
  Delete "$SMPROGRAMS\${APP_NAME}\Uninstall.lnk"
  Delete "$SMPROGRAMS\${APP_NAME}\Start ${APP_NAME}.lnk"
  RMDir  "$SMPROGRAMS\${APP_NAME}"

  ; Registry.
  DeleteRegKey HKCU "${ARP_KEY}"
  DeleteRegKey HKCU "Software\${APP_ID}"
  DeleteRegKey HKCU "Software\Classes\redactproof"
SectionEnd

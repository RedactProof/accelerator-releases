; RedactProof Accelerator - branded launcher stub
;
; This is the target of the redactproof:// URL scheme AND (via --direct) the
; single silent launcher for the bridge. Two jobs:
;
; 1. BRANDING. Pointing the protocol handler straight at schtasks.exe works,
;    but the browser then asks "Open Task Scheduler Configuration Tool?" -
;    schtasks.exe's own Windows file description, which reads like malware.
;    Chrome shows the target executable's FileDescription, so this stub with
;    FileDescription="RedactProof Accelerator" turns the prompt into
;    "Open RedactProof Accelerator?".
;
; 2. SILENT LAUNCH (--direct). This replaced start-bridge.vbs. The vbs
;    (wscript.exe running a hidden-window script from AppData) is a catalogued
;    attacker technique, and Defender's ML flagged it as
;    Trojan:Win32/Commando.A!ml on a customer machine (2026-08-21). ExecShell
;    with SW_HIDE sets the same STARTUPINFO wShowWindow the vbs did, so the
;    node console stays hidden - without wscript in the process tree. Do NOT
;    reintroduce wscript/powershell wrappers here; the hidden-scripting-host
;    pattern is what trips AV, regardless of what the script does.
;
; Invoked WITHOUT arguments (protocol handler, start-menu shortcut) it starts
; the bridge THROUGH the scheduled task: schtasks posts an RPC to the
; Scheduler service and exits, so the bridge is launched by the Scheduler in
; its own session, outside the browser's Job Object. A bridge spawned directly
; from a protocol handler inherits that Job Object and is killed when the
; browser closes. Invoked WITH --direct (HKCU\Run autostart, the scheduled
; task's own action, install-time launch - contexts with no hostile Job
; Object) it spawns node itself.
;
; Built by build.ps1 into the payload BEFORE the installer is compiled, so it
; ships inside $INSTDIR.
;
; RequestExecutionLevel user is deliberate and load-bearing: asking for admin
; would put a UAC prompt in front of every "Start Accelerator" click.

!include "LogicLib.nsh"
!include "FileFunc.nsh"

!ifndef APP_VERSION
  !define APP_VERSION "0.0.0"
!endif
!ifndef OUT_FILE
  !define OUT_FILE "..\dist\LaunchAccelerator.exe"
!endif
!define APP_ID "RedactProofAccelerator"

Name "RedactProof Accelerator"
OutFile "${OUT_FILE}"
RequestExecutionLevel user
SilentInstall silent
Icon "assets\app.ico"

VIProductVersion "${APP_VERSION}.0"
VIAddVersionKey "ProductName" "RedactProof Accelerator"
VIAddVersionKey "CompanyName" "Popsall Ltd"
VIAddVersionKey "FileVersion" "${APP_VERSION}"
VIAddVersionKey "ProductVersion" "${APP_VERSION}"
; This is the string the browser's "wants to open this application" prompt
; shows. Keep it human and branded.
VIAddVersionKey "FileDescription" "RedactProof Accelerator"
VIAddVersionKey "LegalCopyright" "(c) Popsall Ltd"

Section
  ${GetParameters} $R0
  ${If} $R0 == "--direct"
    ; Autostart / task-action path: spawn the bridge ourselves, hidden.
    Call DirectLaunch
  ${Else}
    ; Browser / shortcut path: let the Scheduler start it, escaping the
    ; browser's Job Object so the bridge outlives the tab that launched it.
    nsExec::Exec 'schtasks.exe /Run /TN "${APP_ID}"'
    Pop $0
    ${If} $0 != 0
      ; The task is missing or refused to run. Launch directly rather than
      ; fail silently - the bridge then shares the browser's lifetime, which
      ; is degraded but still starts the thing the user asked for.
      Call DirectLaunch
    ${EndIf}
  ${EndIf}
SectionEnd

Function DirectLaunch
  ; SetOutPath fixes the child's working directory (server.mjs resolves its
  ; assets relative to itself, but keep cwd sane anyway). SW_HIDE keeps the
  ; node console window from appearing - honoured by conhost via STARTUPINFO,
  ; exactly what the old vbs's Run(..., 0, ...) did.
  SetOutPath "$EXEDIR"
  ExecShell "open" "$EXEDIR\node.exe" '"$EXEDIR\server.mjs"' SW_HIDE
FunctionEnd

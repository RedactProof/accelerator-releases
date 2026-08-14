; RedactProof Accelerator - branded launcher stub
;
; This is the target of the redactproof:// URL scheme. It exists for one
; reason: BRANDING. Pointing the protocol handler straight at schtasks.exe
; works, but the browser then asks
;
;     "Open Task Scheduler Configuration Tool?"
;
; because that is schtasks.exe's own Windows file description. A user being
; asked to let a website open the Windows Task Scheduler reasonably reads that
; as malware. Chrome shows the target executable's FileDescription, so a tiny
; stub of our own with FileDescription="RedactProof Accelerator" turns the
; prompt into "Open RedactProof Accelerator?".
;
; It still starts the bridge THROUGH the scheduled task, which is the whole
; point of the task: schtasks posts an RPC to the Scheduler service and exits,
; so the bridge is launched by the Scheduler in its own session, outside the
; browser's Job Object. A bridge spawned directly from a protocol handler
; inherits that Job Object and is killed when the browser closes.
;
; Built by build.ps1 into the payload BEFORE the installer is compiled, so it
; ships inside $INSTDIR alongside start-bridge.vbs.
;
; RequestExecutionLevel user is deliberate and load-bearing: asking for admin
; would put a UAC prompt in front of every "Start Accelerator" click.

!include "LogicLib.nsh"

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
  ; Preferred path: let the Scheduler start it, escaping the browser's Job
  ; Object so the bridge outlives the tab that launched it.
  nsExec::Exec 'schtasks.exe /Run /TN "${APP_ID}"'
  Pop $0
  ${If} $0 != 0
    ; The task is missing or refused to run. Launch directly rather than fail
    ; silently - the bridge then shares the browser's lifetime, which is
    ; degraded but still starts the thing the user asked for.
    Exec '"wscript.exe" "$EXEDIR\start-bridge.vbs"'
  ${EndIf}
SectionEnd

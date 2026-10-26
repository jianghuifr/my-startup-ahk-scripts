#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon

; Started by Windows when the DeepSeek Harness attention toast is clicked: the
; monitor script registers the dsh-attention: protocol for this file (see
; startup\SpecificPrograms\DeepSeekHarnessAttension.ahk).  It only has to put
; the app window in front - restoring it first when it sits in the tray - and
; then get out of the way; the monitor itself keeps running.
#Include ..\startup\lib\dshwin.ahk

Dsh_Activate()
ExitApp

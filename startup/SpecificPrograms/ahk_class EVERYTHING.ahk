#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

; The former #z (launch/activate Everything) is gone: Windows 11 uses Win+Z for
; the snap layouts, and Everything is launched from its own shortcut / tray icon.

#HotIf WinActive("ahk_class EVERYTHING")
^l:: {
    ControlFocus("Edit1", "ahk_class EVERYTHING")
    Send("^a")
}
!Enter:: {
    command := ControlGetText("Edit1", "ahk_class EVERYTHING")
    if (command = "")
        return
    ; Both paths are quoted: a Desktop redirected into a folder with spaces
    ; would otherwise break "cd /d".
    Run('"' A_ComSpec '" /K cd /d "' A_Desktop '" && cls && ' command)
}
#HotIf

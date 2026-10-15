#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

#z:: {
    if !WinExist("ahk_class EVERYTHING")
        Run("everything")
    WinActivate("ahk_class EVERYTHING")
}

#HotIf WinActive("ahk_class EVERYTHING")
^l:: {
    ControlFocus("Edit1", "ahk_class EVERYTHING")
    Send("^a")
}
!Enter:: {
    command := ControlGetText("Edit1", "ahk_class EVERYTHING")
    Run(A_ComSpec " /K cd /d " A_Desktop " && cls && " command)
}
#HotIf

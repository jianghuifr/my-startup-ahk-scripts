#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

#Include %A_ScriptDir%\lib\system.ahk

SetCapsLockState("AlwaysOff")
CapsLock:: {
    ToolTip(GetKeyState("CapsLock", "T") ? "CapsLock On" : "CapsLock Off", 0, 0)
    SetTimer(RemoveToolTip, 3000)
}
+CapsLock::SetCapsLockState(!GetKeyState("CapsLock", "T") ? "On" : "Off")

RemoveToolTip(*) {
    ToolTip()
}
;-------------------------------------------------------------------------------
; ^Space::WinSetAlwaysOnTop(-1, "A")  ; use powertoys instead (ctrl+win+t)
;-------------------------------------------------------------------------------
; Every path handed to cmd is quoted: folder names may contain spaces.
^#c::RunCmd('"' A_ComSpec '" /K cd /d "' CurrentFolder() '"')
^+#c::RunCmd('*RunAs "' A_ComSpec '" /K cd /d "' CurrentFolder() '"')
^#p::RunCmd('"' A_ComSpec '" /K cd /d "' CurrentFolder() '" && Powershell')
^+#p::RunCmd('*RunAs "' A_ComSpec '" /K cd /d "' CurrentFolder() '" && Powershell')
;-------------------------------------------------------------------------------
^+#z::RunCmd("Explorer shell:::{ED7BA470-8E54-465E-825C-99712043E01C}") ; all tasks
;-------------------------------------------------------------------------------
^#!Down::Send("{Volume_Down}")
^#!Left::Send("{Media_Prev}")
^#!Right::Send("{Media_Next}")
^#!Space::Send("{Media_Play_Pause}")
^#!Enter::Send("{Media_Stop}")
;-------------------------------------------------------------------------------
^+#Up::system_SetScreenBrightness(5)
^+#Down::system_SetScreenBrightness(-5)
;-------------------------------------------------------------------------------
#`::SwitchToSimilarWindow()
;-------------------------------------------------------------------------------
~RButton & WheelDown::Send("{Blind}+{WheelDown}")
~RButton & WheelUp::Send("{Blind}+{WheelUp}")
;===============================================================================
RunCmd(cmd) {
    try Run(cmd)
}

CurrentFolder(hWnd := 0) {
    ; Prefer the active Explorer window over "some" Explorer window.
    if (!hWnd) {
        hWnd := WinActive("A")
        cls := SafeWindowClass(hWnd)
        if (cls != "CabinetWClass" && cls != "ExploreWClass")
            hWnd := WinExist("ahk_class CabinetWClass") || WinExist("ahk_class ExploreWClass")
    }
    if (hWnd) {
        try {
            shell := ComObject("Shell.Application")
            for win in shell.Windows {
                if (win.hWnd = hWnd)
                    return win.Document.Folder.Self.Path
            }
        }
    }
    return EnvGet("USERPROFILE")
}

SafeWindowClass(hwnd) {
    try
        return WinGetClass("ahk_id " hwnd)
    catch
        return ""
}

SwitchToSimilarWindow() {
    MouseGetPos(, , &mouse_id)
    if (!mouse_id)
        return
    mouse_class := WinGetClass("ahk_id " mouse_id)
    mouse_exe := WinGetProcessName("ahk_id " mouse_id)
    if (mouse_class = "" || mouse_exe = "")
        return

    ids := []
    titles := []
    for this_id in WinGetList(, , "Program Manager") {
        this_exe := WinGetProcessName("ahk_id " this_id)
        this_class := WinGetClass("ahk_id " this_id)
        this_title := WinGetTitle("ahk_id " this_id)
        if (this_class = mouse_class && this_exe = mouse_exe) {
            ids.Push(this_id)
            titles.Push(this_title)
        }
    }
    if (!ids.Length) {
        ToolTip(mouse_exe "`n(no window of this class)")
        SetTimer(() => ToolTip(), -1200)
        return
    }
    index := ShowToolTip(mouse_exe, titles)

    ; "#`" -> "`": strip the leading modifier symbols. (Only single-key hotkeys
    ; use this, not "a & b" combinations.)
    key := RegExReplace(A_ThisHotKey, "^[\*\~\$\#\+\!\^]+")
    Loop {
        if !GetKeyState("LWin", "P") {
            try WinActivate("ahk_id " ids[index])
            ToolTip()
            break
        }
        KeyWait(key)
        if KeyWait(key, "D T0.2") ; pressed again within 0.2s -> advance selection
            index := ShowToolTip(mouse_exe, titles, index)
    }
}

ShowToolTip(mouse_exe, titles, index := 1) {
    index += 1
    index := (index > titles.Length) ? (index - titles.Length) : index
    _title := mouse_exe "`n"
    for i, title in titles {
        if (i = index)
            _title .= ">"
        _title .= "`t" title "`n"
    }
    ToolTip(_title, , , 1)
    return index
}

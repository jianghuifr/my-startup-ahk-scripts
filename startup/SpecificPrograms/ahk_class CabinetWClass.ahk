#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

#HotIf WinActive("ahk_class WorkerW")
^h::ShowHideFiles()
#HotIf WinActive("ahk_class CabinetWClass")
^h::ShowHideFiles()
#HotIf WinActive("ahk_class CabinetWClass") && MouseIsOver("CabinetWClass", "DirectUIHWND2")
MButton::!Up
#HotIf WinActive("ahk_class CabinetWClass") && MouseIsOver("CabinetWClass", "DirectUIHWND3")
MButton::!Up
#HotIf WinActive("ahk_class CabinetWClass") || WinActive("ahk_class Progman") || WinActive("ahk_class WorkerW")
^+m::CurrentWindowNewFile() ; Ctrl+Shift+M: create new, empty, extensionless file in the active explorer window or on the desktop
#HotIf

CurrentWindowNewFile() {
    shellWindows := ComObject("Shell.Application").Windows
    if (WinActive("ahk_class Progman") || WinActive("ahk_class WorkerW")) {
        _hwnd := Buffer(4, 0)
        explorerWin := shellWindows.FindWindowSW(0, "", 8, ComValue(0x4003, _hwnd.Ptr), 1)
    } else {
        hwnd := WinExist("A")
        title := WinGetTitle("ahk_id " hwnd)
        for explorerWin in shellWindows {
            if (hwnd = explorerWin.Hwnd && explorerWin.Document.Folder.Self.Path = title)
                break
        }
    }
    sfv := explorerWin.Document
    items := sfv.SelectedItems
    Loop items.Count
        sfv.SelectItem(items.Item(A_Index - 1), 0)
    newFileName := "New File"
    if FileExist(sfv.Folder.Self.Path "\" newFileName) {
        Loop {
            newFileName := "New File (" (A_Index + 1) ")"
            if !FileExist(sfv.Folder.Self.Path "\" newFileName)
                break
        }
    }
    FileAppend("", sfv.Folder.Self.Path "\" newFileName)
    explorerWin.Refresh()
    sfv.SelectItem(items.Item(newFileName), 1)
    Loop 5 { ; Loop usually isn't necessary, but adds a bit of reliability.
        Sleep(50)
        Send("{F2}")
        ; Verify we're now in rename mode.
        focusHwnd := ControlGetFocus("A")
        focus := focusHwnd ? ControlGetClassNN(focusHwnd) : ""
    } until (focus = "Edit1")
}

MouseIsOver(class, control := "") {
    MouseGetPos(, , &id, &ctrl)
    return (WinGetClass("ahk_id " id) = class) && ((ctrl = control) || !control)
}

ShowHideFiles() {
    key := "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    status := RegRead(key, "Hidden", 2)
    if (status = 2)
        RegWrite(1, "REG_DWORD", key, "Hidden")
    else
        RegWrite(2, "REG_DWORD", key, "Hidden")
    PostMessage(0x111, 28931, , , "A")

    shellWindows := ComObject("Shell.Application").Windows
    Loop shellWindows.Count {
        explorerWin := shellWindows.Item(A_Index - 1)
        explorerWin.Refresh()
    }
}

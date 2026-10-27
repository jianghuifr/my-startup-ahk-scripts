#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

SetWinDelay(-1)
DetectHiddenWindows(false)
CoordMode("Mouse")

; system-defined drag threshold, used to tell a click apart from a drag
DRAG_X := SysGet(68) ; SM_CXDRAG
DRAG_Y := SysGet(69) ; SM_CYDRAG

~LButton & RButton:: {
    global DRAG_X, DRAG_Y
    if WinActive("ahk_exe mstsc.exe") ; except mstsc.exe
        return
    if WinActive("ahk_class WorkerW") || WinActive("ahk_class Progman") ; except desktop
        return
    if WinActive("ahk_class Windows.UI.Core.CoreWindow") ; except start menu
        return

    MouseGetPos(&M_O_x, &M_O_y, &Win) ; mouse origin + target window
    Target := "ahk_id " Win
    if !WinExist(Target) ; the window is already gone
        return
    ; Windows pinned by a winplace rule snap back as soon as they are moved, so
    ; dragging one would only be a tug of war. Clicks still maximize/restore.
    pinned := IsPinnedByRule(Win)
    M_P_x := M_O_x ; previous mouse position (for incremental move)
    M_P_y := M_O_y
    WinGetPos(&W_O_x, &W_O_y, , , Target) ; window origin position
    min_max_state := WinGetMinMax(Target)

    moved := false
    Loop {
        if !GetKeyState("LButton", "P") ; left button up -> end gesture (right may be released earlier)
            break
        if !WinExist(Target) ; the window vanished mid-drag -> nothing left to move, end gesture
            return
        if GetKeyState("Escape", "P") { ; Escape -> cancel, move window back to origin
            if (moved && min_max_state = 0)
                TryWinMove(Target, W_O_x, W_O_y)
            return
        }

        MouseGetPos(&M_C_x, &M_C_y)
        if (!moved && (Abs(M_C_x - M_O_x) >= DRAG_X || Abs(M_C_y - M_O_y) >= DRAG_Y))
            moved := true ; crossed the drag threshold -> this is a drag, not a click
        if (moved && min_max_state = 0 && !pinned) { ; live move, only when the window is in normal state
            ; WinExist() above only narrows the race: the window can still be destroyed
            ; between these calls, so a vanished window must not raise TargetError.
            if !TryWinGetPos(Target, &W_C_x, &W_C_y)
                return
            TryWinMove(Target, W_C_x + M_C_x - M_P_x, W_C_y + M_C_y - M_P_y)
        }
        M_P_x := M_C_x
        M_P_y := M_C_y
        Sleep(10)
    }

    if (!moved && WinExist(Target)) { ; no movement -> a click -> toggle maximize / restore
        if (min_max_state = 1) ; maximized -> restore
            WinRestore(Target)
        else if (min_max_state = 0) ; normal/restored -> maximize
            WinMaximize(Target)
        ; minimized (min_max_state = -1) -> leave unchanged
    }
}

; The dragged window can be destroyed at any moment (closed by the user, recreated
; by the app, ...). WinGetPos/WinMove then throw TargetError, which would pop up the
; error dialog and abort the gesture. These wrappers report the vanished window
; instead of raising, so the gesture just ends quietly.
TryWinGetPos(win, &x, &y) {
    try {
        WinGetPos(&x, &y, , , win)
        return true
    } catch TargetError {
        return false
    }
}

TryWinMove(win, x, y) {
    try {
        WinMove(x, y, , , win)
        return true
    } catch TargetError {
        return false
    }
}

; Windows managed by a winplace rule (Explorer, EverythingCenter) carry the
; owning script's PID as a window property. The
; property can outlive a crashed placement script, so the owner must be alive
; for the window to count as pinned.
IsPinnedByRule(hwnd) {
    pid := DllCall("GetPropW", "Ptr", hwnd, "WStr", "AHK_WinPlace_Owner", "Ptr")
    return (pid && ProcessExist(pid)) ? true : false
}

; =============================================================================
; dshwin.ahk -- find and bring up the DeepSeek Harness main window
; -----------------------------------------------------------------------------
; Shared by the attention monitor (it asks whether the app window is already
; active) and by tools\DSHActivate.ahk, the protocol handler a toast click
; starts.
;
;   Dsh_FindWindow(&state)   main window handle; state receives "visible",
;                            "minimized", "hidden" or "" when there is none
;   Dsh_Activate()           restore/show and focus the window; true when it
;                            ended up in front
;
; The app is Electron: its windows use Chrome's window class, which browsers
; share, so the process name is what identifies it.  Hidden helper windows
; (Chromium creates several) are filtered out by requiring the app's own window
; class and a title.
; =============================================================================

Dsh_Exe := "DeepSeek Harness.exe"

Dsh_FindWindow(&state) {
    global Dsh_Exe

    state := ""
    for hwnd in WinGetList("ahk_exe " Dsh_Exe) {
        if (WinGetMinMax("ahk_id " hwnd) = -1)
            continue
        if (Dsh_IsAppWindow(hwnd)) {
            state := "visible"
            return hwnd
        }
    }

    for hwnd in WinGetList("ahk_exe " Dsh_Exe) {
        if (WinGetMinMax("ahk_id " hwnd) != -1)
            continue
        if (Dsh_IsAppWindow(hwnd, true)) {
            state := "minimized"
            return hwnd
        }
    }

    DetectHiddenWindows(true)
    hidden := 0
    try {
        for hwnd in WinGetList("ahk_exe " Dsh_Exe) {
            if (DllCall("IsWindowVisible", "Ptr", hwnd))
                continue
            if (Dsh_IsAppWindow(hwnd, true)) {
                hidden := hwnd
                break
            }
        }
    } finally {
        DetectHiddenWindows(false)
    }
    if (hidden)
        state := "hidden"
    return hidden
}

; A real application window needs a title bar, which means both WS_BORDER and
; WS_DLGFRAME.  For minimized and hidden candidates also require the app's own
; window class and a title, so the app's hidden helper windows are never
; mistaken for the main window.
Dsh_IsAppWindow(hwnd, strict := false) {
    try {
        if (strict && WinGetClass("ahk_id " hwnd) != "Chrome_WidgetWin_1")
            return false
        if ((WinGetStyle("ahk_id " hwnd) & 0x00C00000) != 0x00C00000)
            return false
        if (strict && WinGetTitle("ahk_id " hwnd) = "")
            return false
    } catch {
        return false
    }
    return true
}

Dsh_Activate() {
    state := ""
    hwnd := Dsh_FindWindow(&state)
    if (!hwnd)
        return false

    ; A minimized window has to be restored, one that was closed to the tray
    ; shown; WinActivate alone does not make a hidden window visible.
    if (state = "minimized")
        DllCall("ShowWindow", "Ptr", hwnd, "Int", 9)      ; SW_RESTORE
    else if (state = "hidden")
        DllCall("ShowWindow", "Ptr", hwnd, "Int", 5)      ; SW_SHOW

    try WinActivate("ahk_id " hwnd)
    if (WinActive("ahk_id " hwnd))
        return true

    ; The foreground lock can still refuse a background process.  Attaching to
    ; the foreground thread for the duration of the call is the standard way
    ; around that.
    fg := DllCall("GetForegroundWindow", "Ptr")
    if (!fg) {
        DllCall("SetForegroundWindow", "Ptr", hwnd)
        return DllCall("GetForegroundWindow", "Ptr") = hwnd
    }
    fgThread := DllCall("GetWindowThreadProcessId", "Ptr", fg, "Ptr", 0, "UInt")
    thisThread := DllCall("GetCurrentThreadId", "UInt")
    DllCall("AttachThreadInput", "UInt", thisThread, "UInt", fgThread, "Int", 1)
    DllCall("SetForegroundWindow", "Ptr", hwnd)
    DllCall("AttachThreadInput", "UInt", thisThread, "UInt", fgThread, "Int", 0)
    return DllCall("GetForegroundWindow", "Ptr") = hwnd
}

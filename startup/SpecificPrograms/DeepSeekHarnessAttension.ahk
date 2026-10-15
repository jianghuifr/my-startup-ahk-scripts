#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon
Persistent

; =============================================================================
; DeepSeek Harness: attention flash
; -----------------------------------------------------------------------------
; The DSH profile plugin "dsh-attention-signal" writes
;     %USERPROFILE%\.dsh\attention-signal.json
; whenever the harness needs a human:
;     kind = "approval"   an approval decision is waiting  (待确认)
;     kind = "idle"       a turn finished                  (完成)
;
; This script watches that file.  When a fresh signal arrives and the desktop
; window is not already the active window, the window is put on top and *stays*
; there: a topmost window is visible over whatever you are working in, and it
; is never taken down because the window happened to become active - clicking
; over by accident must not end the reminder.  You take it down yourself when
; the matter is actually settled (the title-bar menu's "Always On Top" entry,
; Ctrl+Space, or your own Always On Top toggle) - and a window you pinned that
; way yourself is never touched.
;
; Notes
;   * Focus is never stolen: the window is only raised, not activated.
;   * A minimized or hidden window is brought back first - ShowWindow with
;     SW_SHOWNOACTIVATE restores it to its previous size and position without
;     taking focus - and is then raised like any other window.  Set
;     ACTIVATE_ON_ALERT to true if it should also be focused.
;   * An already active window is skipped: you are looking at it.
;   * The plugin's two idle sources (turn end and agent status) can arrive as a
;     pair; repeats of the same kind inside DEDUPE_MS are ignored.
;   * Set TOP_MS below to a nonzero value if you want the flash to time out
;     instead of waiting for you.
; =============================================================================

; -----------------------------------------------------------------------------
; Settings
; -----------------------------------------------------------------------------
TARGET_EXE  := "DeepSeek Harness.exe"                                ; app window
SIGNAL_FILE := EnvGet("USERPROFILE") "\.dsh\attention-signal.json"   ; written by the plugin
POLL_MS     := 250        ; how often to look at the signal file
TOP_MS      := 0          ; 0 = stay on top until you cancel it yourself;
                          ; otherwise milliseconds to stay on top (e.g. 12000)
DEDUPE_MS   := 1500       ; ignore a repeat of the same kind within this window
ACTIVATE_ON_ALERT := false ; true = also give the window focus when it is
                           ; restored/raised; false = never steal focus
RESTORE_HIDDEN := true     ; true = a window hidden to the tray is brought back
                           ; too; false = leave a deliberately hidden window
                           ; alone (a minimized one is still restored)

; -----------------------------------------------------------------------------
; State
; -----------------------------------------------------------------------------
LastRaw    := ""          ; last signal content we looked at
LastKind   := ""
LastTick   := 0
TopHwnd    := 0           ; window WE put on top (0 = we set nothing)
TopUntil   := 0           ; when to take it down again (TOP_MS > 0 only)

; Window property the neighbour script WinAlwaysOnTop sets on windows the user
; pinned: never take the topmost state away from one of those.
PIN_PROP := "AHK_AlwaysOnTop_Pinned"

; -----------------------------------------------------------------------------
; Go
; -----------------------------------------------------------------------------
LastRaw := ReadSignal()   ; an old file must not fire at startup
SetTimer(Tick, POLL_MS)
OnExit(OnExitHandler)

ReadSignal() {
    global SIGNAL_FILE
    try
        return Trim(FileRead(SIGNAL_FILE, "UTF-8"))
    catch
        return ""
}

Tick() {
    global LastRaw

    ; The window can vanish between AppWindow() and the calls on it; a timer
    ; thread must never raise the error dialog, so everything is guarded.
    try {
        raw := ReadSignal()
        if (raw != "" && raw != LastRaw) {
            LastRaw := raw
            HandleSignal(raw)
        }
        RevertIfDue()
    }
}

HandleSignal(raw) {
    global TARGET_EXE, DEDUPE_MS, TOP_MS, ACTIVATE_ON_ALERT, RESTORE_HIDDEN
    global LastKind, LastTick, TopHwnd, TopUntil

    kind := ""
    if (RegExMatch(raw, '"kind"\s*:\s*"([A-Za-z]+)"', &m))
        kind := m[1]
    if (kind = "")
        return

    now := A_TickCount
    if (kind = LastKind && now - LastTick < DEDUPE_MS)
        return
    LastKind := kind
    LastTick := now

    state := ""
    hwnd := AppWindow(&state)
    if (!hwnd)
        return
    if (state = "visible" && WinActive("ahk_id " hwnd))
        return                               ; you are already looking at it
    if (state = "hidden" && !RESTORE_HIDDEN)
        return                               ; hidden on purpose - leave it be

    if (state != "visible") {
        ; Minimized or hidden: bring it back to its previous size and position
        ; without taking focus (SW_SHOWNOACTIVATE = 4).
        DllCall("ShowWindow", "Ptr", hwnd, "Int", 4)
        Sleep(150)                           ; let the shell finish the transition
    }

    if (ACTIVATE_ON_ALERT)
        try WinActivate("ahk_id " hwnd)

    ; Raise it (again): this also puts it above other topmost windows, and it
    ; stays there until you cancel it yourself.
    WinSetAlwaysOnTop(1, "ahk_id " hwnd)
    TopHwnd := hwnd
    TopUntil := TOP_MS > 0 ? now + TOP_MS : 0
}

; The real application window whatever state it is in: a restored one first,
; then a minimized one, then a hidden one.  state receives "visible",
; "minimized" or "hidden" ("" when nothing was found).
AppWindow(&state) {
    global TARGET_EXE

    state := ""
    for hwnd in WinGetList("ahk_exe " TARGET_EXE) {
        if (WinGetMinMax("ahk_id " hwnd) = -1)
            continue
        if (IsAppWindow(hwnd)) {
            state := "visible"
            return hwnd
        }
    }

    for hwnd in WinGetList("ahk_exe " TARGET_EXE) {
        if (WinGetMinMax("ahk_id " hwnd) != -1)
            continue
        if (IsAppWindow(hwnd, true)) {
            state := "minimized"
            return hwnd
        }
    }

    DetectHiddenWindows(true)
    hidden := 0
    try {
        for hwnd in WinGetList("ahk_exe " TARGET_EXE) {
            if (DllCall("IsWindowVisible", "Ptr", hwnd))
                continue
            if (IsAppWindow(hwnd, true)) {
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
; window class and a title, so the app's hidden helper windows (Chromium creates
; several) are never mistaken for the main window.
IsAppWindow(hwnd, strict := false) {
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

; Only relevant when TOP_MS is set: the flash times out on its own.
RevertIfDue() {
    global TopHwnd, TopUntil
    if (!TopHwnd || !TopUntil)
        return
    if (!WinExist("ahk_id " TopHwnd)) {
        TopHwnd := 0
        return
    }
    if (A_TickCount >= TopUntil) {
        ClearOurTopmost(TopHwnd)
        TopHwnd := 0
    }
}

; Take the topmost state away only from a window this script raised - never
; from one the user pinned with WinAlwaysOnTop.
ClearOurTopmost(hwnd) {
    global PIN_PROP
    if (DllCall("GetPropW", "Ptr", hwnd, "WStr", PIN_PROP, "Ptr"))
        return
    try WinSetAlwaysOnTop(0, "ahk_id " hwnd)
}

OnExitHandler(*) {
    global TopHwnd
    if (TopHwnd && WinExist("ahk_id " TopHwnd))
        ClearOurTopmost(TopHwnd)
}

#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon
Persistent

; =============================================================================
; DeepSeek Harness: attention toast
; -----------------------------------------------------------------------------
; The DSH profile plugin "dsh-attention-signal" writes
;     %USERPROFILE%\.dsh\attention-signal.json
; whenever the harness needs a human:
;     kind = "approval"   an approval decision is waiting  (待确认)
;     kind = "idle"       a turn finished                  (完成)
;
; This script watches that file and, when a fresh signal arrives while the app
; window is not the active one, shows a Windows toast notification
; (tools\DSHToast.ps1).  The toast is sent with the app's own AppUserModelID
; (com.deepseek.dsh, from its Start Menu shortcut), so it carries the DeepSeek
; Harness name and icon instead of a generic script identity, and its priority
; is High, so it can break through Do Not Disturb when the user allows priority
; notifications.
;
; Clicking the toast launches the dsh-attention: protocol.  This script
; registers it at startup and points it at tools\DSHActivate.ahk, which
; restores the window (also from the tray or from a minimized state) and brings
; it to the front.  Nothing is pinned on top and focus is never taken without
; that click.
;
; Notes
;   * An already active window is skipped: you are looking at it.
;   * Repeats of the same kind inside DEDUPE_MS are ignored - the plugin's two
;     idle sources can arrive as a pair.
;   * No window (the app was closed): no toast, there would be nothing to
;     switch to.
;   * The toast times out on its own but stays in the notification centre,
;     where it can still be clicked later.
; =============================================================================

#Include %A_ScriptDir%\..\lib\dshwin.ahk

; -----------------------------------------------------------------------------
; Settings
; -----------------------------------------------------------------------------
SIGNAL_FILE     := EnvGet("USERPROFILE") "\.dsh\attention-signal.json"   ; written by the plugin
POLL_MS         := 250        ; how often to look at the signal file
DEDUPE_MS       := 1500       ; ignore a repeat of the same kind within this window
LOG_FILE        := A_ScriptDir "\..\..\error.log"
TOAST_SCRIPT    := A_ScriptDir "\..\..\tools\DSHToast.ps1"
ACTIVATE_SCRIPT := A_ScriptDir "\..\..\tools\DSHActivate.ahk"
PROTOCOL        := "dsh-attention"

; -----------------------------------------------------------------------------
; State
; -----------------------------------------------------------------------------
LastRaw  := ""            ; last signal content we looked at
LastKind := ""
LastTick := 0

; -----------------------------------------------------------------------------
; Go
; -----------------------------------------------------------------------------
LastRaw := ReadSignal()   ; an old file must not fire at startup
RegisterProtocol()
SetTimer(Tick, POLL_MS)

ReadSignal() {
    global SIGNAL_FILE
    try
        return Trim(FileRead(SIGNAL_FILE, "UTF-8"))
    catch
        return ""
}

Tick() {
    global LastRaw

    ; A timer thread must never raise the error dialog, so everything is guarded.
    try {
        raw := ReadSignal()
        if (raw != "" && raw != LastRaw) {
            LastRaw := raw
            HandleSignal(raw)
        }
    }
}

HandleSignal(raw) {
    global DEDUPE_MS, LastKind, LastTick

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
    hwnd := Dsh_FindWindow(&state)
    if (!hwnd)
        return                                   ; no window to offer
    if (state = "visible" && WinActive("ahk_id " hwnd))
        return                                   ; you are already looking at it

    ShowToast(kind)
}

ShowToast(kind) {
    if (kind = "approval")
        SendToast("DeepSeek Harness 需要确认"
            , "有审批请求在等待。点击这条消息切换到 DeepSeek Harness。")
    else if (kind = "idle")
        SendToast("DeepSeek Harness 回合结束"
            , "任务已完成。点击这条消息切换到 DeepSeek Harness。")
    else
        SendToast("DeepSeek Harness"
            , "有新的提醒。点击这条消息切换到 DeepSeek Harness。")
}

; tools\DSHToast.ps1 needs Windows PowerShell (5.1): it is the one with the
; WinRT projection for Windows.UI.Notifications.  Run it hidden - the toast is
; the only thing that should be seen.
SendToast(title, text) {
    global TOAST_SCRIPT, PROTOCOL

    if (!FileExist(TOAST_SCRIPT)) {
        LogLine("toast helper not found: " TOAST_SCRIPT)
        return
    }

    ps := A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe"
    args := "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden"
    args .= ' -File "' TOAST_SCRIPT '"'
    args .= ' -Title "' title '"'
    args .= ' -Text "' text '"'
    args .= ' -Launch "' PROTOCOL ':activate"'

    try Run('"' ps '" ' args, , "Hide")
    catch as e
        LogLine("could not start the toast helper: " e.Message)
}

; Windows launches the registered command when the toast is clicked.  The
; command is rewritten whenever the script or the interpreter moved, so a
; relocated checkout keeps working.
RegisterProtocol() {
    global PROTOCOL, ACTIVATE_SCRIPT

    key := "HKCU\Software\Classes\" PROTOCOL
    cmd := '"' A_AhkPath '" "' ACTIVATE_SCRIPT '" "%1"'

    existing := ""
    try existing := RegRead(key "\shell\open\command", "")
    if (existing = cmd)
        return

    try {
        RegCreateKey(key)
        RegCreateKey(key "\shell\open\command")
        RegWrite("URL:" PROTOCOL, "REG_SZ", key)
        RegWrite("", "REG_SZ", key, "URL Protocol")
        RegWrite(cmd, "REG_SZ", key "\shell\open\command")
    } catch as e {
        LogLine("could not register the " PROTOCOL ": protocol: " e.Message)
    }
}

; Failures (the toast helper missing, PowerShell refusing, ...) are rare but
; silent otherwise; keep them next to the other scripts' errors.
LogLine(text) {
    global LOG_FILE
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") " attention: " text "`n", LOG_FILE)
}

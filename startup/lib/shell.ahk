; =============================================================================
; shell.ahk -- Shell.Application helpers shared by HotKeys.ahk and Explorer.ahk
; -----------------------------------------------------------------------------
; Several Explorer tabs can share one HWND, so a window handle alone is
; ambiguous.  Shell_WindowForHwnd() prefers the tab whose folder path equals the
; window title (Explorer shows the path as the title for a plain folder) and
; falls back to the first handle match, so there is one implementation instead
; of two slightly different ones.
; =============================================================================

; The Shell.Application window (a tab) belonging to hwnd, or 0.
Shell_WindowForHwnd(hwnd) {
    if (!hwnd || !DllCall("IsWindow", "Ptr", hwnd))
        return 0
    try {
        windows := ComObject("Shell.Application").Windows
    } catch {
        return 0
    }
    title := ""
    try title := WinGetTitle("ahk_id " hwnd)
    first := 0
    for w in windows {
        try sameHwnd := (w.Hwnd = hwnd)
        catch
            sameHwnd := false
        if (!sameHwnd)
            continue
        if (!first)
            first := w
        try {
            if (w.Document.Folder.Self.Path = title)
                return w
        }
    }
    return first
}

; Folder path of the Explorer window, or "" when it cannot be determined
; (virtual folders such as This PC or search results do not have a plain path).
Shell_FolderPath(hwnd) {
    w := Shell_WindowForHwnd(hwnd)
    if (!w)
        return ""
    try {
        path := w.Document.Folder.Self.Path
        return (Type(path) = "String") ? path : ""
    } catch {
        return ""
    }
}

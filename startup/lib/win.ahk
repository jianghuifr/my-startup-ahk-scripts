; Window helpers (AutoHotkey v2)

; True if the window has the WS_EX_TOPMOST style.
win_IsTopmost(hwnd) {
    return (WinGetExStyle("ahk_id " hwnd) & 0x8) ? true : false
}

; ============================================================================
; DPI coordinate space
; ----------------------------------------------------------------------------
; DwmGetWindowAttribute always reports PHYSICAL pixels, but the coordinates given
; to window APIs (UpdateLayeredWindow, SetWindowPos, window regions, ...) live in
; the calling thread's DPI context. When those differ - a DPI-unaware thread, or a
; DPI-aware process whose cached system DPI predates the current display scaling -
; Windows multiplies the coordinates by the DPI factor, so a window asked to sit
; at the target's physical rect lands at scale x that position.
;
; win_InitCoordSpace() puts the thread into the PER_MONITOR_AWARE_V2 context (the
; coordinates are then physical and match DWM) and returns how many physical
; pixels one unit of this thread's coordinates covers: 1.0 when that succeeded,
; otherwise the DPI factor, which callers must divide DWM rectangles by.
; ============================================================================
win_InitCoordSpace() {
    win_UsePhysicalPixelCoords()
    return win_MeasureCoordScale()
}

; Put this thread in the PER_MONITOR_AWARE_V2 DPI context so window coordinates
; are physical pixels, matching what DwmGetWindowAttribute reports.
win_UsePhysicalPixelCoords() {
    try {
        ; DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4
        return DllCall("SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr") ? true : false
    } catch {
        return false
    }
}

; Physical pixels per unit of this thread's window coordinates. Measured by asking
; a probe window for two known positions and reading back where it really landed,
; which stays correct whatever DPI context the thread ended up in.
win_MeasureCoordScale() {
    scale := 1.0
    probe := 0
    try {
        probe := Gui("-Caption +ToolWindow -DPIScale")
        probe.Show("NA Hide")
        ax := 0, ay := 0, bx := 0, by := 0
        win_ProbeCoords(probe.Hwnd, 1000, 600, &ax, &ay)
        win_ProbeCoords(probe.Hwnd, 2000, 1200, &bx, &by)
        sx := (bx - ax) / 1000
        sy := (by - ay) / 600
        ; Only trust a plausible, uniform result; anything else keeps 1:1.
        if (sx > 0.2 && sx < 8 && sy > 0.2 && sy < 8 && Abs(sx - sy) < 0.05)
            scale := (sx + sy) / 2
    }
    if (probe)
        probe.Destroy()
    return scale
}

; Move hwnd to (x,y) and report the physical position it ended up at.
win_ProbeCoords(hwnd, x, y, &px, &py) {
    DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", 0, "Int", x, "Int", y, "Int", 100, "Int", 100
        , "UInt", 0x14)  ; SWP_NOZORDER | SWP_NOACTIVATE
    rect := Buffer(16, 0)
    DllCall("dwmapi\DwmGetWindowAttribute", "Ptr", hwnd, "UInt", 9, "Ptr", rect, "UInt", 16)
    px := NumGet(rect, 0, "Int")
    py := NumGet(rect, 4, "Int")
}

; Radius, in physical pixels, of the rounded corners Windows 11 draws on this
; window; 0 when the window has square corners (or DWM does not report any).
; DWMWA_WINDOW_CORNER_PREFERENCE: 0 default, 1 do-not-round, 2 round, 3 round-small;
; the radii are the Win11 ones (8 DIP, 4 DIP for small) scaled by the window's DPI.
win_GetCornerRadius(hwnd) {
    pref := Buffer(4, 0)
    if (DllCall("dwmapi\DwmGetWindowAttribute", "Ptr", hwnd, "UInt", 33, "Ptr", pref, "UInt", 4) != 0)
        return 0
    p := NumGet(pref, 0, "Int")
    if (p = 1)               ; DWMWCP_DONOTROUND
        return 0
    dpi := 0
    try dpi := DllCall("GetDpiForWindow", "Ptr", hwnd, "UInt")
    if (!dpi)
        dpi := 96
    return Round(((p = 3) ? 4 : 8) * dpi / 96)
}

; Visible (DWM extended-frame) bounds of a window in screen coords, excluding
; the invisible resize border. Falls back to WinGetPos if DWM is unavailable.
win_GetVisibleRect(hwnd, &x, &y, &w, &h) {
    rect := Buffer(16, 0)
    hr := DllCall("dwmapi\DwmGetWindowAttribute", "Ptr", hwnd, "UInt", 9, "Ptr", rect, "UInt", 16)
    if (hr = 0) {
        x := NumGet(rect, 0, "Int")
        y := NumGet(rect, 4, "Int")
        w := NumGet(rect, 8, "Int") - x
        h := NumGet(rect, 12, "Int") - y
    } else {
        WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)
    }
}

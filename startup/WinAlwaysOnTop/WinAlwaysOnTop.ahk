#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon
Persistent

#Include %A_ScriptDir%\..\lib\gdip.ahk
#Include %A_ScriptDir%\..\lib\win.ahk

; ==============================================================================
; State
; ==============================================================================
global PinnedWindows := Map()   ; target hwnd -> {gui, overlay, x, y, w, h}
global InjectedMenus := Map()   ; hwnd -> true (windows we injected a menu item into)
global LastForeground := 0
global LastToggleHwnd := 0
global LastToggleTick := 0

; ==============================================================================
; Config
; ==============================================================================
global SHADOW := 1               ; border width in pixels
global SHADOW_COLOR := 0x1E90FF  ; DodgerBlue (RGB) - used when RAINBOW is off
global SHADOW_ALPHA := 255       ; max alpha at inner edge

; Rainbow flowing border
global RAINBOW := true       ; true -> animated rainbow border, false -> solid SHADOW_COLOR
global HUE_OFFSET := 0        ; current hue scroll offset (degrees), advanced by the timer
global RAINBOW_SPAN := 360    ; total hue degrees spread around the whole border
global RAINBOW_SPEED := 3     ; degrees of hue scroll per animation tick

global MATH_PI := 3.141592653589793  ; AHK v2 has no PI builtin

; Custom command ID - must match DLL's SC_TOGGLE_TOPMOST
global SC_TOGGLE_TOPMOST := 0xE001

; Window property marking windows pinned by THIS script. Stored on the target
; window itself, so it survives a script crash and lets us re-adopt on restart.
global PIN_PROP := "AHK_AlwaysOnTop_Pinned"

; Physical pixels per unit of this thread's window coordinates. Overlay rects come
; from DWM (physical pixels), so they must be divided by this before being handed
; to window APIs. It is 1.0 unless the thread could not be made DPI aware.
global WIN_COORD_SCALE := 1.0

; ==============================================================================
; Startup
; ==============================================================================
; Overlay windows are positioned with DWM's physical-pixel rectangles, so make
; sure this thread's window coordinates are physical pixels too; otherwise the OS
; scales them by the DPI factor and the border lands beside the window.
WIN_COORD_SCALE := win_InitCoordSpace()

; Start GDI+
global pToken := gdip_Startup()

; Load hook DLL and install global hook
global hHookDll := DllCall("LoadLibrary", "Str", A_ScriptDir "\WinAlwaysOnTop_hook_v2.dll", "Ptr")
if (!hHookDll) {
    MsgBox("Failed to load WinAlwaysOnTop_hook_v2.dll`nMake sure it's in: " A_ScriptDir, "Error", 16)
    ExitApp()
}

; Register the same message name as the DLL and listen for the toggle message
global WM_TOGGLE := DllCall("RegisterWindowMessageA", "AStr", "WM_AHKTOP_TOGGLE", "UInt")
OnMessage(WM_TOGGLE, OnToggleTopmost)

if (!DllCall(A_ScriptDir "\WinAlwaysOnTop_hook_v2.dll\InstallHook", "Int")) {
    MsgBox("Failed to install global hook", "Error", 16)
    ExitApp()
}

OnExit(OnExitHandler)

; Re-adopt any windows we previously pinned, and inject the menu item into all
; currently open windows.
InitExistingWindows()

SetTimer(WatchPinnedWindows, 30)
SetTimer(InjectMenuOnForeground, 200)
if (RAINBOW)
    SetTimer(AnimateRainbow, 50)

; ==============================================================================
; Ctrl+Space hotkey
; ==============================================================================
^Space:: {
    hwnd := WinExist("A")
    if (hwnd)
        TogglePin(hwnd)
}

; ==============================================================================
; Startup: adopt previously-pinned windows + inject menu into open windows
; ==============================================================================
InitExistingWindows() {
    for hwnd in WinGetList(, , "Program Manager") {
        title := WinGetTitle("ahk_id " hwnd)
        if (title = "")
            continue
        cls := WinGetClass("ahk_id " hwnd)
        if (cls = "Shell_TrayWnd" || cls = "Shell_SecondaryTrayWnd")
            continue
        InjectSysMenuItem(hwnd)
        ; Adopt windows WE pinned (marked with our prop) that are still topmost,
        ; not e.g. Snipaste windows that happen to be topmost.
        if (win_IsTopmost(hwnd) && DllCall("GetPropW", "Ptr", hwnd, "WStr", PIN_PROP, "Ptr"))
            CreateOverlay(hwnd)
    }
}

; ==============================================================================
; Small helpers
; ==============================================================================
IsOwnOverlay(hwnd) {
    for _, info in PinnedWindows
        if (info.overlay = hwnd)
            return true
    return false
}

; Overlay rect (window rect grown by the border) in the coordinate space this
; thread's window APIs use; info holds the target's physical DWM rect.
OverlayRect(info, &x, &y, &w, &h) {
    s := WIN_COORD_SCALE
    x := Round((info.x - SHADOW) / s)
    y := Round((info.y - SHADOW) / s)
    w := Round((info.w + SHADOW * 2) / s)
    h := Round((info.h + SHADOW * 2) / s)
}

; ==============================================================================
; System menu injection: add "📌 Always On Top" to foreground window
; ==============================================================================
InjectMenuOnForeground() {
    hwnd := WinExist("A")
    if (!hwnd)
        return
    if (IsOwnOverlay(hwnd))  ; skip our own overlay windows
        return
    InjectSysMenuItem(hwnd)
}

InjectSysMenuItem(hwnd) {
    hMenu := DllCall("GetSystemMenu", "Ptr", hwnd, "Int", 0, "Ptr")
    if (!hMenu)
        return
    if (DllCall("GetMenuItemCount", "Ptr", hMenu, "Int") < 0)
        return

    ; Decide by the live menu state rather than the InjectedMenus map, so a
    ; recycled window handle whose new window lacks the item gets re-injected.
    state := DllCall("GetMenuState", "Ptr", hMenu, "UInt", SC_TOGGLE_TOPMOST, "UInt", 0x0, "Int")  ; MF_BYCOMMAND
    if (state != -1) {
        InjectedMenus[hwnd] := true
        return
    }

    flags := win_IsTopmost(hwnd) ? 0x8 : 0x0  ; MF_CHECKED or MF_UNCHECKED

    ; Insert our item at the top, then a separator below it.
    DllCall("InsertMenuW", "Ptr", hMenu, "UInt", 0, "UInt", 0x400 | flags, "UPtr", SC_TOGGLE_TOPMOST, "WStr", "📌 Always On Top")  ; MF_BYPOSITION
    DllCall("InsertMenuW", "Ptr", hMenu, "UInt", 1, "UInt", 0x400 | 0x800, "UPtr", 0, "Ptr", 0)  ; MF_BYPOSITION | MF_SEPARATOR

    InjectedMenus[hwnd] := true
}

UpdateSysMenuCheck(hwnd) {
    hMenu := DllCall("GetSystemMenu", "Ptr", hwnd, "Int", 0, "Ptr")
    if (!hMenu)
        return
    flags := win_IsTopmost(hwnd) ? 0x8 : 0x0  ; MF_CHECKED or MF_UNCHECKED
    DllCall("CheckMenuItem", "Ptr", hMenu, "UInt", SC_TOGGLE_TOPMOST, "UInt", flags)
}

; ==============================================================================
; Handle toggle notification from the DLL hook
; ==============================================================================
OnToggleTopmost(wParam, lParam, msg, hwnd) {
    global LastToggleHwnd, LastToggleTick
    targetHwnd := wParam
    ; Debounce: ignore duplicate within 200ms for same window (dual hook may fire twice)
    tick := A_TickCount
    if (targetHwnd = LastToggleHwnd && (tick - LastToggleTick) < 200)
        return
    LastToggleHwnd := targetHwnd
    LastToggleTick := tick
    TogglePin(targetHwnd)
    UpdateSysMenuCheck(targetHwnd)
}

; ==============================================================================
; Core toggle - shared by hotkey, system menu, and tray menu
; ==============================================================================
TogglePin(hwnd) {
    if (win_IsTopmost(hwnd)) {  ; unpin
        WinSetAlwaysOnTop(0, "ahk_id " hwnd)
        DllCall("RemovePropW", "Ptr", hwnd, "WStr", PIN_PROP)
        RemoveOverlay(hwnd)
    } else {                    ; pin
        WinSetAlwaysOnTop(1, "ahk_id " hwnd)
        DllCall("SetPropW", "Ptr", hwnd, "WStr", PIN_PROP, "Ptr", 1)
        CreateOverlay(hwnd)
    }
    UpdateSysMenuCheck(hwnd)
}

; ==========================================================================
; Overlay management
; ==========================================================================
CreateOverlay(targetHwnd) {
    if (PinnedWindows.Has(targetHwnd))
        return
    ; v2 GUIs are objects - hold the reference directly, no name/HWND lookup.
    g := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x80000 +E0x20")
    g.Show("NA Hide")
    win_GetVisibleRect(targetHwnd, &wx, &wy, &ww, &wh)
    PinnedWindows[targetHwnd] := {gui: g, overlay: g.Hwnd, x: wx, y: wy, w: ww, h: wh
        , r: win_GetCornerRadius(targetHwnd)}
    DrawShadow(targetHwnd)
}

RemoveOverlay(targetHwnd) {
    if (!PinnedWindows.Has(targetHwnd))
        return
    PinnedWindows[targetHwnd].gui.Destroy()
    PinnedWindows.Delete(targetHwnd)
}

DrawShadow(targetHwnd) {
    if (!PinnedWindows.Has(targetHwnd))
        return

    info := PinnedWindows[targetHwnd]
    overlayHwnd := info.overlay
    ; overlay GUI may have been destroyed by a concurrent toggle/cleanup
    if (!DllCall("IsWindow", "Ptr", overlayHwnd))
        return

    OverlayRect(info, &ox, &oy, &ow, &oh)

    DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", ow, "Int", oh, "Int", 0, "Int", 0x26200A, "Ptr", 0, "Ptr*", &pBitmap := 0)
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", pBitmap, "Ptr*", &pGraphics := 0)
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", pGraphics, "Int", 4)

    ; Border path geometry: the overlay rectangle inset by half the border width,
    ; with the target window's corner radius (0 = square corners). Named `rad`
    ; because AHK variable names are case-insensitive and `R` below is the red
    ; channel of SHADOW_COLOR.
    W := ow - SHADOW
    H := oh - SHADOW
    rad := Min(info.r / WIN_COORD_SCALE, W / 2, H / 2)

    if (RAINBOW) {
        ; Draw the border as colored segments along the perimeter, hue mapped to
        ; position so it forms a continuous rainbow; HUE_OFFSET scrolls it. The
        ; path follows the window's rounded corners (Win11) when it has any.
        straightW := W - 2 * rad
        straightH := H - 2 * rad
        perim := 2 * (straightW + straightH) + 2 * MATH_PI * rad
        if (perim >= 1) {
            segLen := 4.0  ; ~4px keeps it smooth without too many draw calls
            segCount := Ceil(perim / segLen)
            half := SHADOW / 2.0
            Loop segCount {
                d := (A_Index - 1) * segLen          ; distance along perimeter
                BorderPathPoint(d, ow, oh, rad, half, &x1, &y1)
                BorderPathPoint(d + segLen, ow, oh, rad, half, &x2, &y2)
                hue := Mod((d / perim) * RAINBOW_SPAN + HUE_OFFSET, 360)
                col := gdip_HsvToColor(hue, 1.0, 1.0, SHADOW_ALPHA)
                DllCall("gdiplus\GdipCreatePen1", "UInt", col, "Float", SHADOW * 1.0, "Int", 2, "Ptr*", &pPen := 0)
                DllCall("gdiplus\GdipDrawLine", "Ptr", pGraphics, "Ptr", pPen, "Float", x1, "Float", y1, "Float", x2, "Float", y2)
                DllCall("gdiplus\GdipDeletePen", "Ptr", pPen)
            }
        }
    } else {
        ; Solid border: concentric rounded outlines fading towards the window.
        R := (SHADOW_COLOR >> 16) & 0xFF
        G := (SHADOW_COLOR >> 8) & 0xFF
        B := SHADOW_COLOR & 0xFF
        Loop SHADOW {
            i := A_Index - 1
            frac := (SHADOW - i) / SHADOW
            alpha := Floor(SHADOW_ALPHA * frac * frac)
            DllCall("gdiplus\GdipCreatePen1", "UInt", (alpha << 24) | (R << 16) | (G << 8) | B, "Float", 1.0, "Int", 2, "Ptr*", &pPen := 0)
            StrokeOutline(pGraphics, pPen, ow, oh, Max(0, rad - i), i + 0.5)
            DllCall("gdiplus\GdipDeletePen", "Ptr", pPen)
        }
    }

    DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "Ptr", pBitmap, "Ptr*", &hBitmap := 0, "UInt", 0)

    hDC_screen := DllCall("GetDC", "Ptr", 0, "Ptr")
    hDC_mem := DllCall("CreateCompatibleDC", "Ptr", hDC_screen, "Ptr")
    hOld := DllCall("SelectObject", "Ptr", hDC_mem, "Ptr", hBitmap, "Ptr")

    pt_pos := Buffer(8, 0)
    NumPut("Int", ox, pt_pos, 0)
    NumPut("Int", oy, pt_pos, 4)

    pt_size := Buffer(8, 0)
    NumPut("Int", ow, pt_size, 0)
    NumPut("Int", oh, pt_size, 4)

    pt_src := Buffer(8, 0)

    blend := Buffer(4, 0)
    NumPut("UChar", 0, blend, 0)
    NumPut("UChar", 0, blend, 1)
    NumPut("UChar", 255, blend, 2)
    NumPut("UChar", 1, blend, 3)

    DllCall("UpdateLayeredWindow"
        , "Ptr", overlayHwnd
        , "Ptr", hDC_screen
        , "Ptr", pt_pos
        , "Ptr", pt_size
        , "Ptr", hDC_mem
        , "Ptr", pt_src
        , "UInt", 0
        , "Ptr", blend
        , "UInt", 2)

    info.gui.Show("NA")
    ; Place overlay at the very top - z-order handled via region clipping
    DllCall("SetWindowPos", "Ptr", overlayHwnd, "Ptr", -1, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x13) ; HWND_TOPMOST

    DllCall("SelectObject", "Ptr", hDC_mem, "Ptr", hOld)
    DllCall("DeleteDC", "Ptr", hDC_mem)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hDC_screen)
    DllCall("DeleteObject", "Ptr", hBitmap)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", pGraphics)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
}

; ----------------------------------------------------------------------------
; Stroke one rounded outline of the overlay border with a 1px pen: the outline
; sits `inset` pixels inside the overlay edge and has corner radius `rad`.
; ----------------------------------------------------------------------------
StrokeOutline(pGraphics, pPen, ow, oh, rad, inset) {
    W := ow - 2 * inset
    H := oh - 2 * inset
    rad := Min(rad, W / 2, H / 2)
    perim := 2 * ((W - 2 * rad) + (H - 2 * rad)) + 2 * MATH_PI * rad
    if (perim < 1)
        return
    segLen := 4.0
    Loop Ceil(perim / segLen) {
        d := (A_Index - 1) * segLen
        BorderPathPoint(d, ow, oh, rad, inset, &x1, &y1)
        BorderPathPoint(d + segLen, ow, oh, rad, inset, &x2, &y2)
        DllCall("gdiplus\GdipDrawLine", "Ptr", pGraphics, "Ptr", pPen, "Float", x1, "Float", y1, "Float", x2, "Float", y2)
    }
}

; ----------------------------------------------------------------------------
; Map a distance `d` along the overlay's border path to a point on it. The path
; is the overlay rectangle inset by `half`, with corner radius `r` (0 = square
; corners); it starts where the top-left corner's arc ends and runs clockwise.
; ----------------------------------------------------------------------------
BorderPathPoint(d, ow, oh, r, half, &px, &py) {
    left := half
    top := half
    right := ow - half
    bottom := oh - half
    straightW := (right - left) - 2 * r
    straightH := (bottom - top) - 2 * r
    arcLen := (MATH_PI / 2) * r
    perim := 2 * (straightW + straightH) + 4 * arcLen
    if (perim <= 0) {
        px := left
        py := top
        return
    }
    if (d < 0 || d >= perim)
        d := Mod(d, perim)
    if (d < straightW) {                       ; top edge, left -> right
        px := left + r + d
        py := top
        return
    }
    d -= straightW
    if (d < arcLen) {                          ; top-right corner
        a := -MATH_PI / 2 + d / r
        px := right - r + r * Cos(a)
        py := top + r + r * Sin(a)
        return
    }
    d -= arcLen
    if (d < straightH) {                       ; right edge, top -> bottom
        px := right
        py := top + r + d
        return
    }
    d -= straightH
    if (d < arcLen) {                          ; bottom-right corner
        a := d / r
        px := right - r + r * Cos(a)
        py := bottom - r + r * Sin(a)
        return
    }
    d -= arcLen
    if (d < straightW) {                       ; bottom edge, right -> left
        px := right - r - d
        py := bottom
        return
    }
    d -= straightW
    if (d < arcLen) {                          ; bottom-left corner
        a := MATH_PI / 2 + d / r
        px := left + r + r * Cos(a)
        py := bottom - r + r * Sin(a)
        return
    }
    d -= arcLen
    if (d < straightH) {                       ; left edge, bottom -> top
        px := left
        py := bottom - r - d
        return
    }
    d -= straightH                             ; top-left corner
    a := MATH_PI + d / r
    px := left + r + r * Cos(a)
    py := top + r + r * Sin(a)
}

; ==========================================================================
; Timer: scroll the rainbow hue and redraw all borders
; ==========================================================================
AnimateRainbow() {
    global HUE_OFFSET
    Critical("On")
    HUE_OFFSET := Mod(HUE_OFFSET + RAINBOW_SPEED, 360)
    for targetHwnd, info in PinnedWindows {
        if (!WinExist("ahk_id " targetHwnd))
            continue
        if (WinGetMinMax("ahk_id " targetHwnd) = -1) ; minimized -> overlay hidden, skip redraw
            continue
        DrawShadow(targetHwnd)
    }
    UpdateOverlayRegions()
    Critical("Off")
}

; ==========================================================================
; Timer: track pinned windows - move/resize/hide overlays, drop closed ones
; ==========================================================================
WatchPinnedWindows() {
    global LastForeground
    Critical("On")
    curFG := WinExist("A")
    fgChanged := (curFG != LastForeground)
    if (fgChanged)
        LastForeground := curFG
    toRemove := []
    needRegionUpdate := fgChanged
    for targetHwnd, info in PinnedWindows {
        ; drop windows that closed or are no longer topmost
        if (!WinExist("ahk_id " targetHwnd) || !win_IsTopmost(targetHwnd)) {
            toRemove.Push(targetHwnd)
            continue
        }
        overlayHwnd := info.overlay
        if (WinGetMinMax("ahk_id " targetHwnd) = -1) {  ; minimized -> hide overlay
            DllCall("ShowWindow", "Ptr", overlayHwnd, "Int", 0)
            continue
        }
        DllCall("ShowWindow", "Ptr", overlayHwnd, "Int", 8)  ; SW_SHOWNA
        win_GetVisibleRect(targetHwnd, &nx, &ny, &nw, &nh)
        moved := (nx != info.x || ny != info.y)
        resized := (nw != info.w || nh != info.h)
        if (moved || resized) {
            info.x := nx, info.y := ny, info.w := nw, info.h := nh
            ; corner radius follows the window's DPI, so re-ask when it may differ
            newR := win_GetCornerRadius(targetHwnd)
            radiusChanged := (newR != info.r)
            info.r := newR
            if (resized || radiusChanged) {
                DrawShadow(targetHwnd)
            } else {
                ; moved only - reposition without redrawing pixels
                OverlayRect(info, &px, &py, &pw, &ph)
                DllCall("SetWindowPos", "Ptr", overlayHwnd, "Ptr", 0
                    , "Int", px, "Int", py
                    , "Int", 0, "Int", 0
                    , "UInt", 0x15) ; SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE
            }
            needRegionUpdate := true
        }
    }
    for hwnd in toRemove {
        DllCall("RemovePropW", "Ptr", hwnd, "WStr", PIN_PROP)
        RemoveOverlay(hwnd)
    }
    if (needRegionUpdate)
        UpdateOverlayRegions()
    Critical("Off")
}

; ==========================================================================
; Region clipping: clip each overlay where windows above it (in z-order) or a
; visible popup menu cover its border.
; ==========================================================================

; Subtract a screen-space rect [rl,rt,rr,rb] from overlay region hRgn whose
; origin is (ox,oy) and size (ow,oh). Returns true if anything was clipped.
ClipRectFromRegion(hRgn, ox, oy, ow, oh, rl, rt, rr, rb) {
    ix1 := ox > rl ? ox : rl
    iy1 := oy > rt ? oy : rt
    ix2 := (ox + ow) < rr ? (ox + ow) : rr
    iy2 := (oy + oh) < rb ? (oy + oh) : rb
    if (ix1 < ix2 && iy1 < iy2) {
        hClip := DllCall("CreateRectRgn", "Int", ix1 - ox, "Int", iy1 - oy, "Int", ix2 - ox, "Int", iy2 - oy, "Ptr")
        DllCall("CombineRgn", "Ptr", hRgn, "Ptr", hRgn, "Ptr", hClip, "Int", 4) ; RGN_DIFF
        DllCall("DeleteObject", "Ptr", hClip)
        return true
    }
    return false
}

UpdateOverlayRegions() {
    if (PinnedWindows.Count = 0)
        return

    ; Build z-order index of all top-level windows (topmost first = lower index)
    DetectHiddenWindows(false)
    zorder := Map()
    for i, wid in WinGetList()
        zorder[wid] := i

    ; A visible popup menu (context menu, tray menu) sits above our topmost
    ; overlays. Grab its screen rect so we can punch it out below.
    menuVisible := false
    if (WinExist("ahk_class #32768")) {
        WinGetPos(&mnx, &mny, &mnw, &mnh, "ahk_class #32768")
        if (mnw > 0 && mnh > 0) {
            menuVisible := true
            menuR := mnx + mnw
            menuB := mny + mnh
        }
    }

    ; For each overlay, clip out areas covered by overlays that sit ABOVE it in
    ; z-order (independent of which window is active), plus any popup menu.
    for targetHwnd, info in PinnedWindows {
        overlayHwnd := info.overlay
        myZ := zorder.Has(targetHwnd) ? zorder[targetHwnd] : 0x7FFFFFFF
        OverlayRect(info, &ox, &oy, &ow, &oh)

        hRgn := DllCall("CreateRectRgn", "Int", 0, "Int", 0, "Int", ow, "Int", oh, "Ptr")
        clipped := false

        if (menuVisible && ClipRectFromRegion(hRgn, ox, oy, ow, oh, mnx, mny, menuR, menuB))
            clipped := true

        for otherHwnd, otherInfo in PinnedWindows {
            if (otherHwnd = targetHwnd)
                continue
            otherZ := zorder.Has(otherHwnd) ? zorder[otherHwnd] : 0x7FFFFFFF
            if (otherZ >= myZ) ; other is below me -> doesn't cover my border
                continue
            OverlayRect(otherInfo, &bx, &by, &bw, &bh)
            if (ClipRectFromRegion(hRgn, ox, oy, ow, oh, bx, by, bx + bw, by + bh))
                clipped := true
        }

        if (clipped) {
            DllCall("SetWindowRgn", "Ptr", overlayHwnd, "Ptr", hRgn, "Int", 1)
            ; region now owned by the window; do NOT delete hRgn
        } else {
            DllCall("SetWindowRgn", "Ptr", overlayHwnd, "Ptr", 0, "Int", 1) ; full border
            DllCall("DeleteObject", "Ptr", hRgn)
        }
    }
}

; ==========================================================================
; Cleanup: unpin windows, remove menu items, uninstall hook, shutdown GDI+
; ==========================================================================
OnExitHandler(reason, code) {
    global PinnedWindows, InjectedMenus
    DllCall(A_ScriptDir "\WinAlwaysOnTop_hook_v2.dll\UninstallHook")
    ; Un-pin all pinned windows and cleanup overlays
    for targetHwnd, info in PinnedWindows {
        try WinSetAlwaysOnTop(0, "ahk_id " targetHwnd)
        DllCall("RemovePropW", "Ptr", targetHwnd, "WStr", PIN_PROP)
        info.gui.Destroy()
    }
    PinnedWindows := Map()
    ; Remove injected menu items from all windows
    for hwnd, _ in InjectedMenus {
        hMenu := DllCall("GetSystemMenu", "Ptr", hwnd, "Int", 0, "Ptr")
        if (hMenu) {
            DllCall("DeleteMenu", "Ptr", hMenu, "UInt", SC_TOGGLE_TOPMOST, "UInt", 0x0)  ; MF_BYCOMMAND
            DllCall("DeleteMenu", "Ptr", hMenu, "UInt", 0, "UInt", 0x400)  ; MF_BYPOSITION separator
        }
    }
    InjectedMenus := Map()
    DllCall("FreeLibrary", "Ptr", hHookDll)
    gdip_Shutdown(pToken)
}

#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon
Persistent

; =============================================================================
; Everything window centering
; -----------------------------------------------------------------------------
; Every Everything (voidtools) main window is kept centered - horizontally and
; vertically - on the window that was active just before it appeared, and is
; given a width and height of RATIO of the monitor work area (see Settings;
; 1/2 as shipped).
;
;   * The size is measured against the screen the window is on - never against
;     the window the user came from.  A small reference window (a dialog, a
;     compact chat) must not shrink Everything to a sliver, and a large one
;     must not dictate the size either; only the centring follows the
;     reference window.
;   * The reference window is sampled when the Everything window shows up, so
;     opening Everything while working in app X centers it over app X.
;   * MIN_W/MIN_H are optional floors for the computed size.  They are 0, so
;     the result is exactly RATIO of the work area; raise them (e.g. 640/400)
;     only if RATIO itself would be too small on this screen.
;   * No usable reference window (started from the tray, nothing else open, ...)?
;     The window is centred on the monitor work area instead.
;   * Moving the window to another screen is respected: while the reference
;     window sits on a different monitor, the window is placed relative to the
;     screen it is on now (that screen's resolution and centre) instead of
;     being pulled back to the reference's screen.
;   * ENFORCE_ALWAYS keeps it there: if the reference window moves or is resized,
;     Everything follows it; if the Everything window is dragged away, it snaps
;     back.  Set it to false to place a window once and never touch it again.
;   * A minimized or maximized Everything window is left alone; restoring or
;     showing it again re-centers it on whatever is active at that moment.
;
; The placement engine (hook + poll + enforcement) lives in ..\lib\winplace.ahk,
; which the Explorer script shares.
; =============================================================================

#Include %A_ScriptDir%\..\lib\winplace.ahk

; -----------------------------------------------------------------------------
; Settings
; -----------------------------------------------------------------------------
EVERYTHING_CLASS := "EVERYTHING"   ; main window class of Everything
RATIO := 1 / 2          ; width/height, as a fraction of the monitor work area
ENFORCE_ALWAYS := true           ; false = only center when a window appears
POLL_MS := 120            ; safety-net check interval (ms)
SETTLE_MS := 1500           ; keep checking this long after a window shows
TOLERANCE := 2              ; px of difference that still counts as centered
MIN_W := 0              ; optional floors for the computed size; 0 =
MIN_H := 0              ; exact RATIO.  Set e.g. 640/400 if RATIO of a
; small screen must not shrink Everything
; to something unusable.
LOG_FILE := A_ScriptDir "\..\..\error.log"

; -----------------------------------------------------------------------------
; Go
; -----------------------------------------------------------------------------
PlacementRule := { classes: [EVERYTHING_CLASS], target: EverythingTarget, enforce: ENFORCE_ALWAYS, settleMs: SETTLE_MS }
PlacementOpts := { pollMs: POLL_MS, tolerance: TOLERANCE, logFile: LOG_FILE }
WinPlace_Start([PlacementRule], PlacementOpts)

; -----------------------------------------------------------------------------
; Size from the monitor the window is on; centring on the one that was active
; before it appeared.  The reference is captured once and kept for the life of
; the window; when it goes away (or was never usable) the window is centred on
; the monitor work area instead.
; -----------------------------------------------------------------------------
EverythingTarget(hwnd, slot, st) {
    global RATIO, MIN_W, MIN_H

    ; The size is RATIO of the screen, not of the reference window: Everything
    ; must look the same no matter which window happened to be active before it
    ; (a small dialog must not shrink it to a sliver, a huge window must not
    ; blow it up).
    aL := 0
    aT := 0
    aR := 0
    aB := 0
    WinPlace_WorkAreaOfWindow(hwnd, &aL, &aT, &aR, &aB)
    sW := aR - aL
    sH := aB - aT

    w := Round(sW * RATIO)
    h := Round(sH * RATIO)
    if (MIN_W && w < MIN_W)
        w := MIN_W
    if (MIN_H && h < MIN_H)
        h := MIN_H

    if (!st.data.Has("ref")) {
        ref := WinPlace_LastRef()
        st.data["ref"] := (ref && ref != hwnd) ? ref : 0
    }
    ref := st.data["ref"]
    if (ref && !WinPlace_IsUsableRef(ref)) {
        fallback := WinPlace_LastRef()
        ref := (WinPlace_IsUsableRef(fallback) && fallback != hwnd) ? fallback : 0
        st.data["ref"] := ref
    }

    ; The window may have been dragged to another screen: keep using the
    ; reference only while both are on the same monitor.  Otherwise place it
    ; relative to the screen it is on now - that screen's resolution and
    ; centre - instead of pulling it back to the screen the reference is on.
    ; (A reference that has gone away reports monitor 0 and drops out here.)
    if (ref && WinPlace_MonitorOfWindow(ref) != WinPlace_MonitorOfWindow(hwnd))
        ref := 0

    if (ref) {
        rX := 0
        rY := 0
        rW := 0
        rH := 0
        WinGetPos(&rX, &rY, &rW, &rH, "ahk_id " ref)
        x := rX + (rW - w) // 2
        y := rY + (rH - h) // 2
    } else {
        x := aL + (sW - w) // 2
        y := aT + (sH - h) // 2
    }

    cX := 0
    cY := 0
    cW := 0
    cH := 0
    WinPlace_ClampToWorkArea(x, y, w, h, &cX, &cY, &cW, &cH)
    return { x: cX, y: cY, w: cW, h: cH }
}

#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon
Persistent

; =============================================================================
; Everything window centering
; -----------------------------------------------------------------------------
; Every Everything (voidtools) main window is kept in the middle of the monitor
; it is on, at RATIO of the work area of that monitor (see Settings; 1/2 as
; shipped).  Size and position only depend on the screen, never on whatever
; happened to be open in front of it: the window lands in the same place every
; time, at the same proportion of the screen.
;
;   * The work area (screen minus taskbar) of the monitor the window is on
;     decides both the size and the centre.  Moving the window to another
;     monitor re-centres and re-sizes it for that screen.
;   * MIN_W/MIN_H are optional floors for the computed size.  They are 0, so
;     the result is exactly RATIO of the work area; raise them (e.g. 640/400)
;     only if RATIO itself would be too small on this screen.
;   * ENFORCE_ALWAYS keeps it there: dragging the window away, snapping it with
;     Win+arrow or resizing it by hand is undone and it goes back to the
;     centre.  Set it to false to place a window once and leave it alone.
;   * A minimized or maximized Everything window is left alone; restoring it
;     centres it again.
;
; The placement engine (hook + poll + enforcement) lives in ..\lib\winplace.ahk,
; which the Explorer and DSH scripts share.
; =============================================================================

#Include ..\lib\winplace.ahk

; -----------------------------------------------------------------------------
; Settings
; -----------------------------------------------------------------------------
EVERYTHING_CLASS := "EVERYTHING"   ; main window class of Everything
RATIO := 1 / 2          ; width/height, as a fraction of the monitor work area
ENFORCE_ALWAYS := true           ; false = only center when a window appears
POLL_MS := 120            ; safety-net check interval (ms)
SETTLE_MS := 1500           ; keep checking this long after a window shows
TOLERANCE := 2              ; px of difference that still counts as centered
MIN_W := 0              ; optional floors for the computed size; 0 = exact
MIN_H := 0              ; RATIO.  Set e.g. 640/400 if RATIO of a small screen
                        ; must not shrink Everything to something unusable.
LOG_FILE := A_ScriptDir "\..\..\error.log"

; -----------------------------------------------------------------------------
; Go
; -----------------------------------------------------------------------------
PlacementRule := { classes: [EVERYTHING_CLASS], target: EverythingTarget, enforce: ENFORCE_ALWAYS, settleMs: SETTLE_MS }
PlacementOpts := { pollMs: POLL_MS, tolerance: TOLERANCE, logFile: LOG_FILE }
WinPlace_Start([PlacementRule], PlacementOpts)

; -----------------------------------------------------------------------------
; Centre the window in the work area of the monitor it is on.
; -----------------------------------------------------------------------------
EverythingTarget(hwnd, slot, st) {
    global RATIO, MIN_W, MIN_H

    ; The size is RATIO of the screen, and the position is that screen's centre
    ; - not the centre of the window the user came from.  A small window on the
    ; left of the screen must not pull Everything to the left.
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

    x := aL + (sW - w) // 2
    y := aT + (sH - h) // 2

    cX := 0
    cY := 0
    cW := 0
    cH := 0
    WinPlace_ClampToWorkArea(x, y, w, h, &cX, &cY, &cW, &cH)
    return { x: cX, y: cY, w: cW, h: cH }
}

#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon
Persistent

; =============================================================================
; DeepSeek Harness desktop window fixation
; -----------------------------------------------------------------------------
; The app's main window is pinned to a fixed geometry on the monitor it
; currently sits on:
;
;   size    RATIO of the monitor work area        (3/4 as shipped)
;   anchor  ANCHOR = "center" (centred on that screen) or "origin"
;           (top-left corner at ORIGIN), 1/10 by default
;   extra windows: each further window gets a stable slot and is shifted by
;           STEP per slot, so they do not sit exactly on top of each other
;
; Moving the window to another screen is respected: everything is recomputed
; from the screen it is on now (that screen's resolution), so it never jumps
; back to the previous screen.
;
; The app is Electron: its windows use Chrome's window class, which browsers
; share, so the rule matches the process name instead and only touches the real
; application window (the app also owns popup menus, dropdowns, tooltips and
; dialogs, which must keep their own geometry).
;
; ENFORCE_ALWAYS keeps the window there: dragging or resizing it by hand snaps
; it back (set it to false to place it once and leave it alone).  Minimized and
; maximized windows are left untouched; restoring or showing one places it anew.
; As with ExplorerPlace, enforcement also undoes Win+Left/Right snapping.
;
; The placement engine (hook + poll + enforcement) lives in ..\lib\winplace.ahk,
; which the Everything and Explorer scripts share.  The target() rect is the
; shared WinPlace_SlotRect() helper, also used by ExplorerPlace.ahk.
; =============================================================================

#Include %A_ScriptDir%\..\lib\winplace.ahk

; -----------------------------------------------------------------------------
; Settings
; -----------------------------------------------------------------------------
TARGET_EXE       := "DeepSeek Harness.exe"   ; process whose windows to manage
RATIO            := 3 / 4          ; width/height, as a fraction of the work area
ANCHOR           := "center"       ; "center" = centred on the screen,
                                   ; "origin" = top-left corner at ORIGIN
ORIGIN           := 1 / 10         ; top-left offset when ANCHOR = "origin"
STEP             := 1 / 10         ; shift added per extra window (per slot)
ENFORCE_ALWAYS   := true           ; false = only place when a window appears
POLL_MS          := 120            ; safety-net check interval (ms)
TOLERANCE        := 2              ; px of difference that still counts as placed
LOG_FILE         := A_ScriptDir "\..\..\error.log"

; -----------------------------------------------------------------------------
; Go
; -----------------------------------------------------------------------------
PlacementRule := {exe: [TARGET_EXE], target: DshTarget, slots: true, enforce: ENFORCE_ALWAYS, appWindow: true}
PlacementOpts := {pollMs: POLL_MS, tolerance: TOLERANCE, logFile: LOG_FILE}
WinPlace_Start([PlacementRule], PlacementOpts)

; -----------------------------------------------------------------------------
; Fixed rect for one window, relative to the work area of the monitor it is
; on.  slot 0 is the plain anchor position; every further slot is shifted by
; STEP, wrapping around once the window would leave the work area.
; -----------------------------------------------------------------------------
DshTarget(hwnd, slot, st) {
    global RATIO, ANCHOR, ORIGIN, STEP
    return WinPlace_SlotRect(hwnd, slot, RATIO, ORIGIN, STEP, ANCHOR)
}

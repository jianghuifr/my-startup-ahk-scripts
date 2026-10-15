#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon
Persistent

; =============================================================================
; Explorer window fixation
; -----------------------------------------------------------------------------
; Every Explorer (file) window is pinned to a fixed geometry on the monitor it
; currently sits on:
;
;   size    RATIO  of the monitor work area        (3/5 as shipped)
;   origin  ORIGIN from its top-left corner        (1/10 as shipped)
;
; Several windows at once:
;   * The size never changes; every window gets a stable slot number and its
;     top-left corner is shifted down/right by STEP (1/10 as shipped), so the
;     windows cascade towards the bottom-right instead of stacking.
;   * Slots are counted per monitor, so one window per monitor still gets the
;     plain ORIGIN position, and the others cascade next to it.
;   * A window keeps its slot until it is closed, hidden or minimized, so
;     closing one window does not shuffle the remaining ones; the freed slot
;     is given to the next window that appears.
;   * Only whole steps that still keep the window inside the work area are
;     used (4 of them at 3/5 size + 1/10 origin); after that the cascade wraps
;     around to the first one.
;
; ENFORCE_ALWAYS keeps windows there: dragging or resizing one by hand snaps it
; back (set it to false to place a window once and leave it alone).  Minimized
; and maximized windows are left untouched; restoring or showing one again
; places it anew.  Note that this also undoes Win+Left/Right snapping: with
; enforcement on, the pin wins over manual placement.
;
; The placement engine (hook + poll + enforcement) lives in ..\lib\winplace.ahk,
; which the Everything and DSH scripts share.  The target() rect is the shared
; WinPlace_SlotRect() helper, also used by DeepSeekHarness.ahk.
; =============================================================================

#Include %A_ScriptDir%\..\lib\winplace.ahk

; -----------------------------------------------------------------------------
; Settings
; -----------------------------------------------------------------------------
EXPLORER_CLASSES := ["CabinetWClass", "ExploreWClass"]  ; Explorer file windows
RATIO := 3 / 5          ; width/height, as a fraction of the work area
ORIGIN := 1 / 10         ; top-left offset, as a fraction of the same
STEP := 1 / 10         ; shift added per extra window (per slot)
ENFORCE_ALWAYS := true           ; false = only place when a window appears
POLL_MS := 120            ; safety-net check interval (ms)
TOLERANCE := 2              ; px of difference that still counts as placed
LOG_FILE := A_ScriptDir "\..\..\error.log"

; -----------------------------------------------------------------------------
; Go
; -----------------------------------------------------------------------------
PlacementRule := { classes: EXPLORER_CLASSES, target: ExplorerTarget, slots: true, enforce: ENFORCE_ALWAYS }
PlacementOpts := { pollMs: POLL_MS, tolerance: TOLERANCE, logFile: LOG_FILE }
WinPlace_Start([PlacementRule], PlacementOpts)

; -----------------------------------------------------------------------------
; Fixed rect for one window, relative to the work area of the monitor it is
; on.  slot 0 is the plain ORIGIN position; every further slot is shifted by
; STEP, wrapping around once the window would leave the work area.
; -----------------------------------------------------------------------------
ExplorerTarget(hwnd, slot, st) {
    global RATIO, ORIGIN, STEP
    return WinPlace_SlotRect(hwnd, slot, RATIO, ORIGIN, STEP)
}

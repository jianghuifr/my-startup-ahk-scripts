#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon
Persistent

; =============================================================================
; Explorer: fixed window geometry + file-manager hotkeys
; -----------------------------------------------------------------------------
; Window placement.  Every Explorer (file) window is pinned to a fixed geometry
; on the monitor it currently sits on:
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
; which the Everything script shares.  The target() rect is the shared
; WinPlace_SlotRect() helper.
;
; Hotkeys.  These used to be the separate ahk_class CabinetWClass.ahk script;
; they now live at the bottom of this one, next to the placement rule:
;   Ctrl+H          show/hide hidden files, then refresh every Explorer window
;   Ctrl+Shift+M    create a new, empty, extensionless file and start renaming
;   Middle click    back (Alt+Up) when over the file list
; =============================================================================

#Include ..\lib\winplace.ahk

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

; -----------------------------------------------------------------------------
; Hotkeys (Explorer windows and the desktop)
; -----------------------------------------------------------------------------
#HotIf WinActive("ahk_class CabinetWClass") || WinActive("ahk_class WorkerW")
^h::ShowHideFiles()
#HotIf

#HotIf WinActive("ahk_class CabinetWClass") && (MouseIsOver("CabinetWClass", "DirectUIHWND2") || MouseIsOver("CabinetWClass", "DirectUIHWND3"))
MButton::!Up
#HotIf

#HotIf WinActive("ahk_class CabinetWClass") || WinActive("ahk_class Progman") || WinActive("ahk_class WorkerW")
^+m::CurrentWindowNewFile() ; Ctrl+Shift+M: create new, empty, extensionless file in the active explorer window or on the desktop
#HotIf

; -----------------------------------------------------------------------------
; Create a new, empty, extensionless file in the active Explorer window (or on
; the desktop) and put it straight into rename mode.
; -----------------------------------------------------------------------------
CurrentWindowNewFile() {
    shellWindows := ComObject("Shell.Application").Windows
    explorerWin := 0
    if (WinActive("ahk_class Progman") || WinActive("ahk_class WorkerW")) {
        _hwnd := Buffer(4, 0)
        explorerWin := shellWindows.FindWindowSW(0, "", 8, ComValue(0x4003, _hwnd.Ptr), 1)
    } else {
        hwnd := WinExist("A")
        title := WinGetTitle("ahk_id " hwnd)
        hwndOnly := 0
        for w in shellWindows {
            if (hwnd != w.Hwnd)
                continue
            ; Several tabs share one HWND: prefer the tab whose folder matches
            ; the window title and keep the first HWND match as a fallback.
            if (!hwndOnly)
                hwndOnly := w
            try {
                if (w.Document.Folder.Self.Path = title) {
                    explorerWin := w
                    break
                }
            }
        }
        if (!explorerWin)
            explorerWin := hwndOnly
    }
    if (!explorerWin) {
        ToolTip("No Explorer window found")
        SetTimer(() => ToolTip(), -2000)
        return
    }

    sfv := explorerWin.Document
    items := sfv.SelectedItems
    Loop items.Count
        sfv.SelectItem(items.Item(A_Index - 1), 0)
    newFileName := "New File"
    if FileExist(sfv.Folder.Self.Path "\" newFileName) {
        Loop {
            newFileName := "New File (" (A_Index + 1) ")"
            if !FileExist(sfv.Folder.Self.Path "\" newFileName)
                break
        }
    }
    try
        FileAppend("", sfv.Folder.Self.Path "\" newFileName)
    catch as e {
        ToolTip("Could not create the file: " e.Message)
        SetTimer(() => ToolTip(), -3000)
        return
    }
    explorerWin.Refresh()
    ; Select the new item through the folder: the collection captured before the
    ; file existed does not contain it, and selecting from that snapshot failed
    ; silently - leaving "New File" where F2 then had nothing to rename.
    newItem := 0
    try newItem := sfv.Folder.ParseName(newFileName)
    if (!newItem) {
        ToolTip("Could not select the new file")
        SetTimer(() => ToolTip(), -3000)
        return
    }
    try sfv.SelectItem(newItem, 1)
    ; F2 starts the in-place rename asynchronously, so poll for the edit control
    ; instead of pressing it again at once - a second F2 commits the edit again
    ; and leaves the file with its default name.
    Loop 4 {
        Send("{F2}")
        Loop 10 {
            Sleep(40)
            focusHwnd := ControlGetFocus("A")
            focus := focusHwnd ? ControlGetClassNN(focusHwnd) : ""
            if (focus = "Edit1")
                return
        }
    }
}

MouseIsOver(class, control := "") {
    MouseGetPos(, , &id, &ctrl)
    if (!id)
        return false
    try
        return (WinGetClass("ahk_id " id) = class) && ((ctrl = control) || !control)
    catch
        return false
}

; -----------------------------------------------------------------------------
; Toggle Explorer's "hidden files" setting and refresh every window so the
; change takes effect immediately (no logging off or restart).
; -----------------------------------------------------------------------------
ShowHideFiles() {
    key := "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    status := RegRead(key, "Hidden", 2)
    if (status = 2)
        RegWrite(1, "REG_DWORD", key, "Hidden")
    else
        RegWrite(2, "REG_DWORD", key, "Hidden")
    PostMessage(0x111, 28931, , , "A") ; WM_COMMAND / explorer refresh

    shellWindows := ComObject("Shell.Application").Windows
    Loop shellWindows.Count {
        explorerWin := shellWindows.Item(A_Index - 1)
        explorerWin.Refresh()
    }
}

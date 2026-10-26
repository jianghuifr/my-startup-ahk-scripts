; =============================================================================
; winplace.ahk -- engine that keeps matched windows at a computed geometry
; -----------------------------------------------------------------------------
; Shared by the per-class scripts in SpecificPrograms\, which include it and
; then call WinPlace_Start:
;
;   #Include ..\lib\winplace.ahk
;   WinPlace_Start([{classes: ["EVERYTHING"], target: MyTarget}], {pollMs: 120})
;
; A rule is an object:
;   classes   array of window classes to manage                        (required)
;   exe       array of process names to manage instead of / as well as
;             classes, e.g. ["DeepSeek Harness.exe"]; needed for Electron
;             apps, whose windows use Chrome's window classes
;   target    FuncObj(hwnd, slot, state) -> {x, y, w, h}                (required)
;             Return "" to leave that window alone for this round.
;   slots     true: every window gets a stable per-monitor slot number,
;             which target() receives as its 2nd parameter       (default false)
;   enforce   true: keep the window there, snapping it back when something
;             moves it; false: place it once, then leave it alone (default true)
;   appWindow true: only manage real application windows - a full title bar
;             (WS_BORDER *and* WS_DLGFRAME), no owner, and not a menu or a
;             dialog; Electron and Chromium apps create plenty of other
;             top-level windows (popup menus, dropdowns, tooltips, dialogs)
;             that must not be moved                        (default false)
;   settleMs  how long to keep correcting a freshly appeared window;
;             apps often restore their own remembered geometry right after
;   onFirst   optional FuncObj(hwnd, state), called once per new window
;
; Opts: {pollMs: 120, tolerance: 2, settleCheckMs: 80, settleMs: 1500, logFile: ""}
;
; The state object handed to target()/onFirst() holds the engine bookkeeping
; (slot, mon, requested tX/tY/tW/tH, achieved eX/eY/eW/eH, settle) plus
; .data, a Map for whatever the rule wants to remember per window.  Rules call
; back into the WinPlace_* helpers below for geometry.
;
; Events are caught with a win-event hook (EVENT_OBJECT_SHOW) and a poll runs
; as a safety net and to enforce the geometry; a window that is hidden,
; minimized or maximized is dropped and re-placed when it comes back.
; =============================================================================

WP_Rules   := []
WP_Opts    := 0
WP_Windows := Map()   ; hwnd -> state
WP_Ref     := 0       ; most recent foreground window no rule manages
WP_Hook    := 0
WP_Callback := 0      ; WinEventProc pointer, freed on exit
WP_Warned  := false

; Window property stamped on every window a rule manages; the value is this
; script's PID. WinMove.ahk reads it so its drag gesture does not fight the
; enforced geometry. The PID is checked too, because the property survives a
; crashed placement script.
WP_OWNER_PROP := "AHK_WinPlace_Owner"

; -----------------------------------------------------------------------------
; Start the engine.  Rules are applied in order; every visible window of a
; rule's classes is kept at the rect its target function returns.
; -----------------------------------------------------------------------------
WinPlace_Start(rules, opts := 0) {
    global WP_Rules, WP_Opts, WP_Windows, WP_Ref, WP_Warned, WP_Hook

    WP_Rules := rules
    WP_Opts := {pollMs: 120, tolerance: 2, settleCheckMs: 80, settleMs: 1500, logFile: ""}
    if (Type(opts) = "Object") {
        ; OwnProps() enumerates a plain object's properties; assigning by
        ; dynamic name is what sets them ([] is Map-only).
        for k, v in opts.OwnProps()
            WP_Opts.%k% := v
    }
    WP_Windows := Map()
    WP_Ref := 0
    WP_Warned := false

    DetectHiddenWindows(false)
    SetWinDelay(-1)

    WP_Hook := WP_InstallShowHook()
    SetTimer(WP_Tick, WP_Opts.pollMs)
    OnExit(WP_ExitHandler)
    WP_Tick()   ; windows that are already open right now
}

WP_ExitHandler(*) {
    global WP_Hook, WP_Callback, WP_Windows, WP_OWNER_PROP
    DllCall("UnhookWinEvent", "Ptr", WP_Hook)   ; NULL is harmless
    WP_Hook := 0
    if (WP_Callback) {
        CallbackFree(WP_Callback)
        WP_Callback := 0
    }
    for hwnd, _ in WP_Windows
        DllCall("RemovePropW", "Ptr", hwnd, "WStr", WP_OWNER_PROP)
}

; =============================================================================
; Discovery
; =============================================================================

; React to a window being shown immediately instead of waiting for the poll,
; so it is placed before the old position can be noticed.
WP_InstallShowHook() {
    global WP_Callback
    static EVENT_OBJECT_SHOW       := 0x8002
    static WINEVENT_OUTOFCONTEXT   := 0x0000
    static WINEVENT_SKIPOWNPROCESS := 0x0002

    WP_Callback := CallbackCreate(WP_OnShowEvent, , 7)
    h := DllCall("SetWinEventHook"
        , "UInt", EVENT_OBJECT_SHOW, "UInt", EVENT_OBJECT_SHOW
        , "Ptr", 0                                          ; hmodWinEventProc
        , "Ptr", WP_Callback                                ; pfnWinEventProc
        , "UInt", 0, "UInt", 0                              ; idProcess, idThread
        , "UInt", WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS
        , "Ptr")
    if (h = 0)
        WP_Log("SetWinEventHook failed, falling back to polling only")
    return h
}

; The hook fires for every object that gets shown (menus, tooltips, ...), so
; keep only whole top-level windows that some rule manages.
WP_OnShowEvent(hook, event, hwnd, idObject, idChild, thread, time) {
    if (idObject != 0 || idChild != 0 || !hwnd)
        return
    try {
        ruleId := WP_RuleForWindow(hwnd)
        if (!ruleId)
            return
        ; Moving a window from inside the hook callback is asking for trouble;
        ; hand the work back to the message queue.
        SetTimer(WP_Sync.Bind(hwnd, ruleId), -1)
    }
}

WP_Tick() {
    global WP_Rules, WP_Windows, WP_Ref, WP_OWNER_PROP

    ; Remember the last foreground window that no rule manages: rules that
    ; place a window relative to whatever the user was working in need it.
    fg := DllCall("GetForegroundWindow", "Ptr")
    if (fg && fg != WP_Ref && !WP_RuleForWindow(fg) && WinPlace_IsUsableRef(fg))
        WP_Ref := fg

    seen := Map()
    for ruleId, rule in WP_Rules {
        for hwnd in WP_WindowsOf(rule) {
            if (!WP_IsManageable(rule, hwnd))
                continue
            seen[hwnd] := true
            WP_Sync(hwnd, ruleId)
        }
    }

    ; Forget windows that are gone, hidden or minimized, so that showing them
    ; again places them anew (and frees their slot).
    for hwnd in WP_Windows.Clone()
        if (!seen.Has(hwnd)) {
            DllCall("RemovePropW", "Ptr", hwnd, "WStr", WP_OWNER_PROP)
            WP_Windows.Delete(hwnd)
        }
}

; Visible and in the normal state: 0 = normal, 1 = maximized, -1 = minimized.
; Minimized and maximized windows are deliberately left alone; a maximized one
; is an explicit user choice, and fighting it would steal focus over and over.
WP_IsTrackable(hwnd) {
    if (!DllCall("IsWindowVisible", "Ptr", hwnd))
        return false
    try {
        return WinGetMinMax("ahk_id " hwnd) = 0
    } catch {
        return false
    }
}

WP_WindowsOf(rule) {
    list := []
    if (rule.HasProp("classes")) {
        for cls in rule.classes
            WP_AppendUnique(list, WinGetList("ahk_class " cls))
    }
    if (rule.HasProp("exe")) {
        for exe in rule.exe
            WP_AppendUnique(list, WinGetList("ahk_exe " exe))
    }
    return list
}

WP_AppendUnique(list, hwnds) {
    for hwnd in hwnds {
        dup := false
        for h in list {
            if (h = hwnd) {
                dup := true
                break
            }
        }
        if (!dup)
            list.Push(hwnd)
    }
}

; Index of the rule managing this window's class or process, 0 when none does.
WP_RuleForWindow(hwnd) {
    global WP_Rules
    if (!hwnd)
        return 0
    cls := ""
    try
        cls := WinGetClass("ahk_id " hwnd)
    if (cls = "")
        return 0
    exe := ""
    for ruleId, rule in WP_Rules {
        if (rule.HasProp("classes")) {
            for c in rule.classes {
                if (cls = c)
                    return ruleId
            }
        }
        if (rule.HasProp("exe")) {
            if (exe = "")
                exe := WP_ProcessName(hwnd)
            for e in rule.exe {
                if (exe = e)
                    return ruleId
            }
        }
    }
    return 0
}

WP_ProcessName(hwnd) {
    try
        return WinGetProcessName("ahk_id " hwnd)
    return ""
}

; Trackable, and satisfying the rule's extra conditions.
WP_IsManageable(rule, hwnd) {
    if (!WP_IsTrackable(hwnd))
        return false

    cls := ""
    try
        cls := WinGetClass("ahk_id " hwnd)
    catch
        return false

    ; A popup menu (#32768) is a normal-looking top-level window of the owning
    ; process, but moving or resizing it wrecks the menu - never touch one.
    if (cls = "#32768")
        return false

    if (rule.HasProp("appWindow") && rule.appWindow) {
        if (cls = "#32770")                            ; dialog box
            return false
        try {
            ; A real title bar needs both WS_BORDER and WS_DLGFRAME (WS_BORDER
            ; alone is a borderless popup), and dialogs/popups are owned.
            if ((WinGetStyle("ahk_id " hwnd) & 0x00C00000) != 0x00C00000)
                return false
            if (DllCall("GetWindow", "Ptr", hwnd, "UInt", 4, "Ptr"))   ; GW_OWNER
                return false
        } catch {
            return false
        }
    }
    return true
}

; =============================================================================
; Placing
; =============================================================================
WP_Sync(hwnd, ruleId) {
    try {
        WP_SyncCore(hwnd, ruleId)
    } catch as e {
        WP_Log("sync failed for " hwnd ": " e.Message)
    }
}

WP_SyncCore(hwnd, ruleId) {
    global WP_Rules, WP_Windows, WP_Opts, WP_OWNER_PROP

    rule := WP_Rules[ruleId]
    if (!WP_IsManageable(rule, hwnd) || WP_RuleForWindow(hwnd) != ruleId)
        return

    if (!WP_Windows.Has(hwnd)) {
        settle := rule.HasProp("settleMs") ? rule.settleMs : WP_Opts.settleMs
        st := {ruleId: ruleId, slot: -1, mon: 0, data: Map()
             , tX: "", tY: "", tW: "", tH: "", eX: "", eY: "", eW: "", eH: ""
             , settle: A_TickCount + settle}
        WP_Windows[hwnd] := st
        ; Stamp the window so other scripts (WinMove.ahk) can tell it is pinned.
        DllCall("SetPropW", "Ptr", hwnd, "WStr", WP_OWNER_PROP
              , "Ptr", DllCall("GetCurrentProcessId", "UInt"))
        if (rule.HasProp("slots") && rule.slots) {
            st.mon := WinPlace_MonitorOfWindow(hwnd)
            st.slot := WP_TakeSlot(ruleId, st.mon, hwnd)
        }
        if (rule.HasProp("onFirst") && rule.onFirst) {
            ; Pull the function out first: obj.fn() would be a method call and
            ; would pass the object as an extra argument.
            onFirstFn := rule.onFirst
            onFirstFn(hwnd, st)
        }
        ; Check again shortly: the app may restore its own geometry right
        ; after the window was shown.
        SetTimer(WP_Sync.Bind(hwnd, ruleId), -WP_Opts.settleCheckMs)
    }
    st := WP_Windows[hwnd]

    ; A window moved to another monitor takes a slot on that monitor.
    if (rule.HasProp("slots") && rule.slots) {
        mon := WinPlace_MonitorOfWindow(hwnd)
        if (mon != st.mon) {
            st.mon := mon
            st.slot := WP_TakeSlot(ruleId, mon, hwnd)
        }
    }

    targetFn := rule.target
    target := targetFn(hwnd, st.slot, st)
    if (!target)
        return

    tX := target.x
    tY := target.y
    tW := target.w
    tH := target.h
    WinGetPos(&cX, &cY, &cW, &cH, "ahk_id " hwnd)

    tol := WP_Opts.tolerance
    enforce := rule.HasProp("enforce") ? rule.enforce : true
    targetChanged := (st.tW = "" || tX != st.tX || tY != st.tY || tW != st.tW || tH != st.tH)
    outOfPlace := (st.eW = "" || Abs(cX - st.eX) > tol || Abs(cY - st.eY) > tol
                || Abs(cW - st.eW) > tol || Abs(cH - st.eH) > tol)

    ; enforce keeps the window in place; without it, only a new window or a
    ; changed target is acted on - plus the settle time, while the app may
    ; still be restoring its own position.
    if (!targetChanged && !(outOfPlace && (enforce || A_TickCount < st.settle)))
        return

    ; Never fight the user while they drag or resize the window by hand, and
    ; not while they are in a menu or in a move/size loop either - those cover
    ; the system menu's Move/Size entries and keyboard-driven moves, which no
    ; mouse button reports.
    if (GetKeyState("LButton", "P") || WP_UserIsBusy())
        return

    if (!WP_TryWinMove(hwnd, tX, tY, tW, tH))
        return

    st.tX := tX
    st.tY := tY
    st.tW := tW
    st.tH := tH
    ; Remember what the window actually accepted: apps enforce minimum sizes
    ; and the shell may adjust the position, so comparing against the real
    ; result instead of against the request avoids an endless move loop.
    aX := 0
    aY := 0
    aW := 0
    aH := 0
    WinGetPos(&aX, &aY, &aW, &aH, "ahk_id " hwnd)
    st.eX := aX
    st.eY := aY
    st.eW := aW
    st.eH := aH
    WP_CheckMoveAccepted(hwnd, tX, tY, tW, tH, aX, aY, aW, aH)
}

; Smallest slot number not used by another window of the same rule that sits
; on the same monitor, so closing a window does not shuffle the others.
WP_TakeSlot(ruleId, mon, exceptHwnd) {
    global WP_Windows
    used := Map()
    for hwnd, st in WP_Windows {
        if (hwnd = exceptHwnd || st.ruleId != ruleId || st.mon != mon || st.slot < 0)
            continue
        used[st.slot] := true
    }
    slot := 0
    while used.Has(slot)
        slot += 1
    return slot
}

; =============================================================================
; Geometry helpers for rules
; =============================================================================

; Work area of the monitor the window currently sits on.
WinPlace_WorkAreaOfWindow(hwnd, &l, &t, &r, &b) {
    WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)
    MonitorGetWorkArea(WinPlace_MonitorAt(x + w // 2, y + h // 2), &l, &t, &r, &b)
}

WinPlace_MonitorOfWindow(hwnd) {
    if (!hwnd || !DllCall("IsWindow", "Ptr", hwnd))
        return 0   ; gone: callers treat 0 as "no such monitor"
    WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)
    return WinPlace_MonitorAt(x + w // 2, y + h // 2)
}

WinPlace_MonitorAt(x, y) {
    loop MonitorGetCount() {
        MonitorGet(A_Index, &mL, &mT, &mR, &mB)
        if (x >= mL && x < mR && y >= mT && y < mB)
            return A_Index
    }
    return MonitorGetPrimary()
}

; The standard "pinned layout" rect used by the Explorer and DSH scripts: a
; rect of `ratio` x the work area of the window's monitor, anchored at `origin`
; of that area (or centred when anchor = "center"), shifted by `step` per slot
; and wrapping around once it would leave the work area.
WinPlace_SlotRect(hwnd, slot, ratio, origin, step, anchor := "origin") {
    l := 0
    t := 0
    r := 0
    b := 0
    WinPlace_WorkAreaOfWindow(hwnd, &l, &t, &r, &b)
    sW := r - l
    sH := b - t

    w := Round(sW * ratio)
    h := Round(sH * ratio)
    if (anchor = "center") {
        x0 := l + (sW - w) // 2
        y0 := t + (sH - h) // 2
    } else {
        x0 := l + Round(sW * origin)
        y0 := t + Round(sH * origin)
    }
    stepX := Round(sW * step)
    stepY := Round(sH * step)

    ; How many shifts still fit before the window would cross the work area
    ; edge (at least one, so a very small screen still cascades by a pixel).
    slotsX := 1
    if (stepX > 0)
        slotsX := Max(1, ((r - w) - x0) // stepX + 1)
    slotsY := 1
    if (stepY > 0)
        slotsY := Max(1, ((b - h) - y0) // stepY + 1)

    x := x0 + Mod(slot, slotsX) * stepX
    y := y0 + Mod(slot, slotsY) * stepY

    cX := 0
    cY := 0
    cW := 0
    cH := 0
    WinPlace_ClampToWorkArea(x, y, w, h, &cX, &cY, &cW, &cH)
    return {x: cX, y: cY, w: cW, h: cH}
}

; Shrink/move a rect so it stays inside the work area of the monitor it covers.
WinPlace_ClampToWorkArea(x, y, w, h, &cx, &cy, &cw, &ch) {
    MonitorGetWorkArea(WinPlace_MonitorAt(x + w // 2, y + h // 2), &aL, &aT, &aR, &aB)
    if (w > aR - aL)
        w := aR - aL
    if (h > aB - aT)
        h := aB - aT
    if (x < aL)
        x := aL
    if (y < aT)
        y := aT
    if (x + w > aR)
        x := aR - w
    if (y + h > aB)
        y := aB - h
    cx := x
    cy := y
    cw := w
    ch := h
}

; The last foreground window that no rule manages - i.e. the window the user
; was working in before one of the managed windows appeared.
WinPlace_LastRef() {
    global WP_Ref
    return WP_Ref
}

; A window worth using as a reference: a visible, not minimized top-level
; window with a caption and a title (skips the desktop, the taskbar, tool
; windows, menus, ...).
WinPlace_IsUsableRef(hwnd) {
    if (!hwnd || !DllCall("IsWindow", "Ptr", hwnd))
        return false
    if (WP_RuleForWindow(hwnd) || !WP_IsTrackable(hwnd))
        return false
    if (DllCall("GetWindowTextLength", "Ptr", hwnd) = 0)
        return false
    try {
        if (!(WinGetStyle("ahk_id " hwnd) & 0x00C00000))     ; WS_CAPTION
            return false
        if (WinGetExStyle("ahk_id " hwnd) & 0x00000080)      ; WS_EX_TOOLWINDOW
            return false
    } catch {
        return false
    }
    return true
}

; =============================================================================
; Misc
; =============================================================================
; True while the foreground thread is inside a menu or a move/size loop.  The
; system menu's Move/Size entries and keyboard-driven moves never press a mouse
; button, so this is what keeps the engine from fighting them.
WP_UserIsBusy() {
    static size := (A_PtrSize = 8) ? 72 : 48   ; GUITHREADINFO
    gti := Buffer(size, 0)
    NumPut("UInt", size, gti, 0)
    if (!DllCall("GetGUIThreadInfo", "UInt", 0, "Ptr", gti))
        return false
    flags := NumGet(gti, 4, "UInt")
    return (flags & 0x0002) || (flags & 0x0004)   ; GUI_INMOVESIZE | GUI_INMENUMODE
}

WP_TryWinMove(hwnd, x, y, w, h) {
    try {
        WinMove(x, y, w, h, "ahk_id " hwnd)
        return true
    } catch TargetError {
        return false   ; the window vanished, nothing to do
    }
}

; A window that will not move usually belongs to an elevated process: a
; non-elevated script cannot move it (UIPI), and the attempt fails silently.
WP_CheckMoveAccepted(hwnd, tX, tY, tW, tH, aX, aY, aW, aH) {
    global WP_Warned
    if (WP_Warned)
        return
    if (Abs(aX - tX) <= 2 && Abs(aY - tY) <= 2 && Abs(aW - tW) <= 2 && Abs(aH - tH) <= 2)
        return
    if (WP_IsProcessElevated(DllCall("GetCurrentProcessId")))
        return   ; we are elevated too, so it is the window's own size limit
    if (WP_IsProcessElevated(WinGetPID("ahk_id " hwnd))) {
        WP_Warned := true
        WP_Log("window belongs to an elevated process, this script does not: it cannot be moved")
        try {
            ToolTip("该窗口以管理员身份运行，本脚本无法移动它。`n"
                  . "请让该程序与本脚本使用相同的权限运行。")
            SetTimer(() => ToolTip(), -8000)
        }
    }
}

WP_IsProcessElevated(pid) {
    hProc := DllCall("OpenProcess", "UInt", 0x1000, "Int", false, "UInt", pid, "Ptr")
    if (!hProc)
        return false
    token := 0
    if (!DllCall("advapi32\OpenProcessToken", "Ptr", hProc, "UInt", 0x0008, "Ptr*", &token)) {
        DllCall("CloseHandle", "Ptr", hProc)
        return false
    }
    size := 0
    DllCall("advapi32\GetTokenInformation", "Ptr", token, "Int", 20, "Ptr", 0, "UInt", 0, "UInt*", &size)
    elevated := false
    if (size) {
        buf := Buffer(size, 0)
        if (DllCall("advapi32\GetTokenInformation", "Ptr", token, "Int", 20, "Ptr", buf, "UInt", size, "UInt*", &size))
            elevated := NumGet(buf, 0, "Int") ? true : false
    }
    DllCall("CloseHandle", "Ptr", token)
    DllCall("CloseHandle", "Ptr", hProc)
    return elevated
}

; Repeated identical complaints (a window that keeps failing) are collapsed.
WP_Log(text) {
    global WP_Opts
    static lastText := "", lastTick := 0
    if (!IsObject(WP_Opts) || WP_Opts.logFile = "")
        return
    if (text = lastText && A_TickCount - lastTick < 5000)
        return
    lastText := text
    lastTick := A_TickCount
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") " winplace: " text "`n", WP_Opts.logFile)
}

#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

; Empty taskbar space, as told apart by UI Automation; see IsTaskbarBlankArea().
; The old test here compared the control under the cursor against the ClassNN
; "Windows.UI.Composition.DesktopWindowContentBridge2", which no longer matches
; anything (the composition bridge is the ...Bridge1 control), so all three
; hotkeys below were dead.
#HotIf IsTaskbarBlankArea()
~LButton:: {
    ; Double click -> Task View. The click count has to come from A_PriorHotkey:
    ; while a mouse button hotkey's own thread sits in KeyWait, further presses
    ; of that button are never delivered to it, so a KeyWait based counter (the
    ; KeyHits() this used to call) only ever counts one click. WindowSwitcher()
    ; is no help either, it returns success but does nothing on current builds,
    ; so the Task View is opened the same way as for the middle click below.
    if (A_PriorHotkey = A_ThisHotKey && A_TimeSincePriorHotkey <= DllCall("GetDoubleClickTime"))
        Send("#{Tab}")
}
WheelUp::Send("{AltDown}{Esc}{AltUp}")
WheelDown::Send("{AltDown}+{Esc}{AltUp}")
#HotIf

; Middle click on empty taskbar space -> Win+Tab (Task View). Empty means the
; taskbar itself, not one of the things sitting on it (Start, pinned/running
; app buttons, tray and clock, taskbar plugins such as TrafficMonitor); see
; IsTaskbarBlankArea().
#HotIf IsTaskbarBlankArea()
MButton::Send("#{Tab}")
#HotIf

; ============================================================================
; Is the cursor on an empty part of a taskbar?
; ----------------------------------------------------------------------------
; Windows 11 paints the whole taskbar with XAML, so its Start button, the
; pinned and running app buttons, the tray icons and any taskbar plugin are not
; child windows that WindowFromPoint could tell apart from the blank rest of
; the taskbar. The UI Automation tree does tell them apart. For the pixel under
; the cursor UIA reports:
;   * empty taskbar space      -> the taskbar frame itself (a Pane, no name,
;                                 AutomationId "TaskbarFrame")
;   * an app button            -> a child Button ("<app> 已固定", an app id...)
;   * a tray icon / the clock  -> a child Button or Image of the SystemTray
;                                 peers, or the input site hosting them
;   * a plugin (TrafficMonitor) or any other elevated window -> the query fails
;     with E_ACCESSDENIED, as that window cannot be inspected from here
; So "the element under the cursor is the taskbar container itself instead of
; one of its children" is exactly the requested empty area, whatever plugin or
; shell change adds further buttons later. The classic (pre-XAML) taskbar is
; covered too: there the container element carries the taskbar window class.
; ============================================================================
IsTaskbarBlankArea() {
    static cursorPos := Buffer(8, 0)       ; POINT, physical screen pixels
    if (!DllCall("GetCursorPos", "Ptr", cursorPos))
        return false
    return IsTaskbarBlankAt(NumGet(cursorPos, 0, "Int"), NumGet(cursorPos, 4, "Int"))
}

; Same question for one screen pixel, which keeps the test usable on its own.
IsTaskbarBlankAt(x, y) {
    try {
        hwnd := DllCall("WindowFromPoint", "Int64", (x & 0xFFFFFFFF) | (y << 32), "Ptr")
        if (!hwnd)
            return false
        hwnd := DllCall("GetAncestor", "Ptr", hwnd, "UInt", 2, "Ptr")   ; GA_ROOT
        winClass := WinGetClass("ahk_id " hwnd)
        if (winClass != "Shell_TrayWnd" && winClass != "Shell_SecondaryTrayWnd")
            return false
        if (WinGetProcessName("ahk_id " hwnd) != "explorer.exe")
            return false
        elem := UiaElementFromPoint(x, y)
        if (!elem)
            return false    ; elevated window (plugin) on top: not empty taskbar
        empty := (UiaProperty(elem, UIA_AutomationId, true) = "TaskbarFrame")   ; Windows 11
              || (UiaProperty(elem, UIA_ClassName, true) = winClass)           ; classic taskbar
        ComCall(2, elem, "UInt")    ; IUnknown::Release
        return empty
    } catch {
        return false        ; a shell or UIA hiccup simply means "no hotkey"
    }
}

; ============================================================================
; Minimal UI Automation interop (no external library)
; ----------------------------------------------------------------------------
; CUIAutomation's interfaces are not IDispatch, so the methods are called
; through the vtable with ComCall(). These indices are part of the frozen
; public UIA API (UIAutomationClient.h) and have never changed.
; ============================================================================
UIA_ElementFromPoint        := 7    ; IUIAutomation::ElementFromPoint(POINT, &elem)
UIA_GetCurrentPropertyValue := 10   ; IUIAutomationElement::GetCurrentPropertyValue(id, &var)
UIA_AutomationId := 30011, UIA_ClassName := 30012

UiaInstance() {
    static _uia := 0        ; kept alive for the lifetime of the script
    if (!_uia) {
        DllCall("ole32\OleInitialize", "Ptr", 0)    ; property values hold BSTRs
        ; CLSID_CUIAutomation / IID_IUIAutomation
        _uia := ComObject("{ff48dba4-60ef-4201-aa87-54103eef594e}", "{30cbe57d-d9d0-452a-ab13-7ac5ac4825ee}")
    }
    return _uia
}

; Element covering the given screen pixel, or 0 if UIA may not look there.
UiaElementFromPoint(x, y) {
    pt := (x & 0xFFFFFFFF) | (y << 32)     ; POINT passed by value
    elem := 0
    hr := ComCall(UIA_ElementFromPoint, UiaInstance(), "Int64", pt, "Ptr*", &elem, "Int")
    return (hr = 0) ? elem : 0
}

; UIA property of an element, as text or as an integer. "" when unsupported.
UiaProperty(elem, propertyId, asText) {
    static VT_I4 := 3, VT_BSTR := 8
    variant := Buffer(24, 0)               ; VARIANT
    if (ComCall(UIA_GetCurrentPropertyValue, elem, "Int", propertyId, "Ptr", variant, "Int") != 0)
        return ""
    value := ""
    variantType := NumGet(variant, 0, "UShort")
    if (asText) {
        if (variantType = VT_BSTR)
            value := StrGet(NumGet(variant, 8, "Ptr"), "UTF-16")
    } else if (variantType = VT_I4) {
        value := NumGet(variant, 8, "Int")
    }
    DllCall("oleaut32\VariantClear", "Ptr", variant)
    return value
}

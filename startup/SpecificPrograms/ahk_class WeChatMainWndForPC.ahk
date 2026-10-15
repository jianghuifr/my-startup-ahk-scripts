#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon
; CoordMode("Pixel", "Client")

#HotIf WinActive("ahk_class WeChatMainWndForPC")
^k:: {
    ; Click's X/Y are relative to the active window's client area (CoordMode was
    ; never changed here), so this follows the window instead of assuming a
    ; screen position.
    Click("160 40")
}
#HotIf

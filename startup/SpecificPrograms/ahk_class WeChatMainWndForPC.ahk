#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon
; CoordMode("Pixel", "Client")

#HotIf WinActive("ahk_class WeChatMainWndForPC")
^k:: {
    MouseMove(160, 40)
    Click("160 40")
}
#HotIf

#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

global Masks := []
global Trans := 15

p := A_Args.Length >= 1 ? A_Args[1] : "000000"  ; default: subtle dim (black at Trans alpha)
if (!FileExist(p) && !RegExMatch(p, "^#?([a-fA-F0-9]{6}|[a-fA-F0-9]{3})$"))
    ExitApp(-1)

monCount := MonitorGetCount()
Loop monCount {
    MonitorGet(A_Index, &monLeft, &monTop, &monRight, &monBottom)
    w := monRight - monLeft
    h := monBottom - monTop
    Masks.Push(CreateMask(p, monLeft, monTop, w, h))
}
return

CreateMask(p, x, y, w, h) {
    global Trans
    g := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x08000000 +E0x20")
    g.MarginX := 0
    g.MarginY := 0

    if FileExist(p)
        g.Add("Picture", "W" w " H" h " Center", p)
    else
        g.BackColor := RegExReplace(p, "^#")  ; strip optional leading '#'

    g.Show("W" w " H" h " X" x " Y" y " NA")
    WinSetTransparent(Trans, g.Hwnd)
    return g.Hwnd
}

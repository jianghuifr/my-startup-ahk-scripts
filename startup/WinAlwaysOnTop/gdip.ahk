; GDI+ helpers (AutoHotkey v2)

; Initialize GDI+. Returns a token to pass to gdip_Shutdown() on exit.
gdip_Startup() {
    DllCall("LoadLibrary", "Str", "gdiplus", "Ptr")
    si := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
    NumPut("UInt", 1, si, 0)
    pToken := 0
    DllCall("gdiplus\GdiplusStartup", "Ptr*", &pToken, "Ptr", si, "Ptr", 0)
    return pToken
}

gdip_Shutdown(pToken) {
    DllCall("gdiplus\GdiplusShutdown", "Ptr", pToken)
}

; HSV (h:0-360, s/v:0-1) -> ARGB UInt for GDI+ (alpha 0-255)
gdip_HsvToColor(h, s, v, a) {
    c := v * s
    hp := h / 60.0
    x := c * (1 - Abs(Mod(hp, 2) - 1))
    if (hp < 1)
        r := c, g := x, b := 0
    else if (hp < 2)
        r := x, g := c, b := 0
    else if (hp < 3)
        r := 0, g := c, b := x
    else if (hp < 4)
        r := 0, g := x, b := c
    else if (hp < 5)
        r := x, g := 0, b := c
    else
        r := c, g := 0, b := x
    m := v - c
    R := Round((r + m) * 255)
    G := Round((g + m) * 255)
    B := Round((b + m) * 255)
    return (a << 24) | (R << 16) | (G << 8) | B
}

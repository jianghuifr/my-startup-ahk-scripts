#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon
Persistent

; =============================================================================
; Clipboard image preview
; -----------------------------------------------------------------------------
; Watches the clipboard: when an image is copied, it is shown in a borderless,
; rounded, always-on-top window next to the mouse cursor.  Copying text (or an
; empty clipboard) hides it again; clicking the preview closes it, copying
; another image replaces it.  No focus is taken, so copying keeps working.
;
; The image is taken from the clipboard as PNG when the source application
; provides that format (alpha preserved), otherwise it is decoded from
; CF_DIB/CF_DIBV5 through GDI+.  It is scaled down - never up - to a share of
; the monitor work area given by MAX_W_RATIO/MAX_H_RATIO, scaled with GDI+
; high-quality interpolation, saved as a PNG and shown in a Picture control.
; The window gets a rounded region so the corners match the light rounded look.
;
; No new dependency: GDI+ is started here, like the WinAlwaysOnTop script does.
; =============================================================================

; -----------------------------------------------------------------------------
; Settings
; -----------------------------------------------------------------------------
MAX_W_RATIO := 1 / 2     ; preview never exceeds this share of the work area
MAX_H_RATIO := 1 / 2
CORNER_RADIUS := 12      ; logical pixels; rounded window corners
CURSOR_OFFSET := 16      ; gap between the mouse cursor and the preview
ALWAYS_ON_TOP := true    ; false = a normal window, can go behind others
AUTO_HIDE_MS := 0        ; 0 = stay until clicked, replaced or text copied
BACK_COLOR := "202020"   ; shows only where the image itself is transparent

PREVIEW_PNG := A_Temp "\clipimg_preview.png"
SOURCE_PNG := A_Temp "\clipimg_source.png"

; -----------------------------------------------------------------------------
; GDI+
; -----------------------------------------------------------------------------
DllCall("LoadLibrary", "Str", "gdiplus", "Ptr")
si := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
NumPut("UInt", 1, si, 0)
gdiplusToken := 0
DllCall("gdiplus\GdiplusStartup", "Ptr*", &gdiplusToken, "Ptr", si, "Ptr", 0)

; -----------------------------------------------------------------------------
; State
; -----------------------------------------------------------------------------
previewGui := 0

OnClipboardChange(ClipChanged)
OnExit(OnExitHandler)
OnMessage(0x0201, OnPreviewButton)   ; WM_LBUTTONDOWN: click closes the preview
OnMessage(0x0204, OnPreviewButton)   ; WM_RBUTTONDOWN
return

; -----------------------------------------------------------------------------
; Clipboard changes: images show a preview, everything else hides it.
; -----------------------------------------------------------------------------
ClipChanged(type) {
    if (type = 2)
        ShowClipboardImage()
    else
        ClosePreview()
}

ShowClipboardImage() {
    global PREVIEW_PNG, MAX_W_RATIO, MAX_H_RATIO, CURSOR_OFFSET, CORNER_RADIUS
    global ALWAYS_ON_TOP, AUTO_HIDE_MS, BACK_COLOR, previewGui

    pBitmap := ClipboardImageBitmap()
    if (!pBitmap)
        return

    iw := 0
    ih := 0
    DllCall("gdiplus\GdipGetImageWidth", "Ptr", pBitmap, "UInt*", &iw)
    DllCall("gdiplus\GdipGetImageHeight", "Ptr", pBitmap, "UInt*", &ih)
    if (!iw || !ih) {
        DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
        return
    }

    ; Fit into the work area of the monitor the cursor is on; never upscale.
    MouseGetPos(&mx, &my)
    MonitorWorkAreaAt(mx, my, &aL, &aT, &aR, &aB)
    maxW := Round((aR - aL) * MAX_W_RATIO)
    maxH := Round((aB - aT) * MAX_H_RATIO)
    scale := Min(1.0, maxW / iw, maxH / ih)
    w := Max(1, Round(iw * scale))
    h := Max(1, Round(ih * scale))

    disp := pBitmap
    if (scale < 1) {
        disp := ScaleBitmap(pBitmap, w, h)
        DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
        if (!disp)
            return
    }
    ok := SavePng(disp, PREVIEW_PNG)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", disp)
    if (!ok)
        return

    ClosePreview()

    ; Place it below-right of the cursor, flipping/clamping so it stays on screen.
    x := mx + CURSOR_OFFSET
    y := my + CURSOR_OFFSET
    if (x + w > aR)
        x := mx - CURSOR_OFFSET - w
    if (y + h > aB)
        y := my - CURSOR_OFFSET - h
    x := Max(aL, Min(x, aR - w))
    y := Max(aT, Min(y, aB - h))

    opts := "-Caption +ToolWindow -DPIScale"
    if (ALWAYS_ON_TOP)
        opts .= " +AlwaysOnTop"
    g := Gui(opts)
    g.BackColor := BACK_COLOR
    g.MarginX := 0
    g.MarginY := 0
    g.Add("Picture", "x0 y0 w" w " h" h, PREVIEW_PNG)
    ; Rounded corners, like a normal app window on Windows 11.
    radius := Round(CORNER_RADIUS * A_ScreenDPI / 96)
    hRgn := DllCall("CreateRoundRectRgn", "Int", 0, "Int", 0, "Int", w + 1, "Int", h + 1
                  , "Int", radius, "Int", radius, "Ptr")
    if (hRgn)
        DllCall("SetWindowRgn", "Ptr", g.Hwnd, "Ptr", hRgn, "Int", 1)
    g.Show("NA x" x " y" y " w" w " h" h)
    previewGui := g

    if (AUTO_HIDE_MS)
        SetTimer(ClosePreview, -AUTO_HIDE_MS)
}

ClosePreview(*) {
    global previewGui
    if (!previewGui)
        return
    SetTimer(ClosePreview, 0)
    try previewGui.Destroy()
    previewGui := 0
}

; A click anywhere on the preview closes it.  WM_LBUTTONDOWN/WM_RBUTTONDOWN for
; one of our own windows arrive here; the click may hit the Picture control, so
; child windows count too.
OnPreviewButton(wParam, lParam, msg, hwnd) {
    global previewGui
    if (!previewGui)
        return
    if (hwnd = previewGui.Hwnd || DllCall("IsChild", "Ptr", previewGui.Hwnd, "Ptr", hwnd))
        ClosePreview()
}

; -----------------------------------------------------------------------------
; Clipboard -> GDI+ bitmap
; -----------------------------------------------------------------------------
ClipboardImageBitmap() {
    global SOURCE_PNG

    ; The copying app can still hold the clipboard open for a moment.
    opened := false
    Loop 10 {
        if (DllCall("OpenClipboard", "Ptr", 0)) {
            opened := true
            break
        }
        Sleep(20)
    }
    if (!opened)
        return 0

    try {
        ; 1) PNG, as most apps that care about transparency provide it.
        pngFormat := DllCall("RegisterClipboardFormatW", "WStr", "PNG", "UInt")
        hPng := pngFormat ? DllCall("GetClipboardData", "UInt", pngFormat, "Ptr") : 0
        if (hPng) {
            size := DllCall("GlobalSize", "Ptr", hPng, "UInt")
            p := DllCall("GlobalLock", "Ptr", hPng, "Ptr")
            if (p && size) {
                data := Buffer(size, 0)
                DllCall("RtlMoveMemory", "Ptr", data, "Ptr", p, "UInt", size)
                DllCall("GlobalUnlock", "Ptr", hPng)
                try FileDelete(SOURCE_PNG)
                fh := FileOpen(SOURCE_PNG, "w")
                fh.RawWrite(data, size)
                fh.Close()
                pBitmap := 0
                DllCall("gdiplus\GdipLoadImageFromFile", "WStr", SOURCE_PNG, "Ptr*", &pBitmap)
                try FileDelete(SOURCE_PNG)
                if (pBitmap)
                    return pBitmap
            }
        }

        ; 2) CF_DIB (8) or CF_DIBV5 (17).  Through GDI's CreateDIBitmap the
        ; pixels are opaque, which is what a screenshot-like DIB means; the
        ; 32-bit alpha of a DIB is not a reliable transparency channel.
        for fmt in [8, 17] {
            hDib := DllCall("GetClipboardData", "UInt", fmt, "Ptr")
            if (!hDib)
                continue
            pInfo := DllCall("GlobalLock", "Ptr", hDib, "Ptr")
            if (!pInfo)
                continue
            pBitmap := 0
            try {
                biSize := NumGet(pInfo, 0, "UInt")
                bitCount := NumGet(pInfo, 14, "UShort")
                clrUsed := (biSize >= 40) ? NumGet(pInfo, 32, "UInt") : 0
                palSize := (bitCount <= 8) ? ((clrUsed ? clrUsed : (1 << bitCount)) * 4) : 0
                pBits := pInfo + biSize + palSize
                hdc := DllCall("GetDC", "Ptr", 0, "Ptr")
                hbm := DllCall("CreateDIBitmap", "Ptr", hdc, "Ptr", pInfo, "UInt", 4
                             , "Ptr", pBits, "Ptr", pInfo, "UInt", 0, "Ptr")
                DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdc)
                if (hbm) {
                    DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", hbm, "Ptr", 0, "Ptr*", &pBitmap)
                    DllCall("DeleteObject", "Ptr", hbm)
                }
                ; GDI+ also understands some DIBV5 headers that CreateDIBitmap
                ; rejects (bit-field masks and friends).
                if (!pBitmap)
                    DllCall("gdiplus\GdipCreateBitmapFromGdiDib", "Ptr", pInfo, "Ptr", pBits, "Ptr*", &pBitmap)
            } finally {
                DllCall("GlobalUnlock", "Ptr", hDib)
            }
            if (pBitmap)
                return pBitmap
        }

        ; 3) CF_BITMAP only (some older applications provide nothing else).
        hBm := DllCall("GetClipboardData", "UInt", 2, "Ptr")
        if (hBm) {
            pBitmap := 0
            DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", hBm, "Ptr", 0, "Ptr*", &pBitmap)
            if (pBitmap)
                return pBitmap
        }
        return 0
    } finally {
        DllCall("CloseClipboard")
    }
}

; -----------------------------------------------------------------------------
; GDI+ helpers
; -----------------------------------------------------------------------------
; High-quality downscale into a new 32bpp bitmap.
ScaleBitmap(src, w, h) {
    pBitmap := 0
    if (DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", w, "Int", h, "Int", 0
             , "Int", 0x26200A, "Ptr", 0, "Ptr*", &pBitmap) != 0 || !pBitmap)
        return 0
    pGraphics := 0
    if (DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", pBitmap, "Ptr*", &pGraphics) != 0 || !pGraphics) {
        DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
        return 0
    }
    DllCall("gdiplus\GdipSetInterpolationMode", "Ptr", pGraphics, "Int", 7)  ; HighQualityBicubic
    DllCall("gdiplus\GdipSetPixelOffsetMode", "Ptr", pGraphics, "Int", 4)    ; HighQuality
    DllCall("gdiplus\GdipDrawImageRectI", "Ptr", pGraphics, "Ptr", src
          , "Int", 0, "Int", 0, "Int", w, "Int", h)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", pGraphics)
    return pBitmap
}

; Save a GDI+ bitmap as PNG (encoder CLSID {557CF406-1A04-11D3-9A73-0000F81EF32E}).
SavePng(pBitmap, path) {
    try FileDelete(path)
    clsid := Buffer(16, 0)
    NumPut("UInt", 0x557CF406, clsid, 0)
    NumPut("UShort", 0x1A04, clsid, 4)
    NumPut("UShort", 0x11D3, clsid, 6)
    for i, b in [0x9A, 0x73, 0x00, 0x00, 0xF8, 0x1E, 0xF3, 0x2E]
        NumPut("UChar", b, clsid, 7 + i)
    hr := DllCall("gdiplus\GdipSaveImageToFile", "Ptr", pBitmap, "WStr", path
                , "Ptr", clsid, "Ptr", 0)
    return (hr = 0 && FileExist(path))
}

; Work area of the monitor containing the point (falls back to the primary).
MonitorWorkAreaAt(x, y, &l, &t, &r, &b) {
    loop MonitorGetCount() {
        MonitorGet(A_Index, &ml, &mt, &mr, &mb)
        if (x >= ml && x < mr && y >= mt && y < mb) {
            MonitorGetWorkArea(A_Index, &l, &t, &r, &b)
            return
        }
    }
    MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
}

OnExitHandler(*) {
    global previewGui, PREVIEW_PNG, SOURCE_PNG, gdiplusToken
    ClosePreview()
    try FileDelete(PREVIEW_PNG)
    try FileDelete(SOURCE_PNG)
    if (gdiplusToken)
        DllCall("gdiplus\GdiplusShutdown", "Ptr", gdiplusToken)
}

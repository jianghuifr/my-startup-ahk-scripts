system_SetScreenBrightness(step) {
    SupportedBrightness := Buffer(256, 0)
    SupportedBrightnessSize := Buffer(4, 0)
    BrightnessSize := Buffer(4, 0)
    Brightness := Buffer(3, 0)

    hLCD := DllCall("CreateFile"
        , "Str", "\\.\LCD"
        , "UInt", 0x80000000 | 0x40000000 ; Read | Write
        , "UInt", 0x1 | 0x2 ; File Read | File Write
        , "UInt", 0
        , "UInt", 0x3 ; open any existing file
        , "UInt", 0
        , "UInt", 0
        , "Ptr")

    if (hLCD != -1) {
        DevVideo := 0x00000023, BuffMethod := 0, Fileacces := 0
        NumPut("UChar", 0x03, Brightness, 0) ; 0x01 = Set AC, 0x02 = Set DC, 0x03 = Set both
        NumPut("UChar", 0x00, Brightness, 1) ; The AC brightness level
        NumPut("UChar", 0x00, Brightness, 2) ; The DC brightness level
        DllCall("DeviceIoControl"
            , "Ptr", hLCD
            , "UInt", (DevVideo << 16 | 0x126 << 2 | BuffMethod << 14 | Fileacces) ; IOCTL_VIDEO_QUERY_DISPLAY_BRIGHTNESS
            , "Ptr", 0
            , "UInt", 0
            , "Ptr", Brightness
            , "UInt", 3
            , "Ptr", BrightnessSize
            , "Ptr", 0)

        DllCall("DeviceIoControl"
            , "Ptr", hLCD
            , "UInt", (DevVideo << 16 | 0x125 << 2 | BuffMethod << 14 | Fileacces) ; IOCTL_VIDEO_QUERY_SUPPORTED_BRIGHTNESS
            , "Ptr", 0
            , "UInt", 0
            , "Ptr", SupportedBrightness
            , "UInt", 256
            , "Ptr", SupportedBrightnessSize
            , "Ptr", 0)

        ACBrightness := NumGet(Brightness, 1, "UChar")
        ACIndex := 0
        DCBrightness := NumGet(Brightness, 2, "UChar")
        DCIndex := 0
        BufferSize := NumGet(SupportedBrightnessSize, 0, "UInt")
        MaxIndex := BufferSize - 1

        Loop BufferSize {
            ThisIndex := A_Index - 1
            ThisBrightness := NumGet(SupportedBrightness, ThisIndex, "UChar")
            if (ACBrightness = ThisBrightness)
                ACIndex := ThisIndex
            if (DCBrightness = ThisBrightness)
                DCIndex := ThisIndex
        }

        if (DCIndex >= ACIndex)
            BrightnessIndex := DCIndex
        else
            BrightnessIndex := ACIndex

        BrightnessIndex += step

        if (BrightnessIndex > MaxIndex)
            BrightnessIndex := MaxIndex

        if (BrightnessIndex < 0)
            BrightnessIndex := 0

        NewBrightness := NumGet(SupportedBrightness, BrightnessIndex, "UChar")

        NumPut("UChar", 0x03, Brightness, 0) ; 0x01 = Set AC, 0x02 = Set DC, 0x03 = Set both
        NumPut("UChar", NewBrightness, Brightness, 1) ; The AC brightness level
        NumPut("UChar", NewBrightness, Brightness, 2) ; The DC brightness level

        DllCall("DeviceIoControl"
            , "Ptr", hLCD
            , "UInt", (DevVideo << 16 | 0x127 << 2 | BuffMethod << 14 | Fileacces) ; IOCTL_VIDEO_SET_DISPLAY_BRIGHTNESS
            , "Ptr", Brightness
            , "UInt", 3
            , "Ptr", 0
            , "UInt", 0
            , "Ptr", 0
            , "Ptr", 0)

        DllCall("CloseHandle", "Ptr", hLCD)

        return BrightnessIndex
    }
}

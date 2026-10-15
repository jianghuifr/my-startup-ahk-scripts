#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon
Persistent

SetWorkingDir(A_ScriptDir)
CoordMode("ToolTip", "Screen")

; will only show the top CharacterCount characters
global CharacterCount := 300
global TEXTS_dir := A_WorkingDir "\cache\"

OnClipboardChange(ClipChanged)
return

ClipChanged(type) {
    global CharacterCount, TEXTS_dir
    ; Contains one of the following values:
    ; 0 if the clipboard is now empty;
    ; 1 if it contains something that can be expressed as text (this includes files copied from an Explorer window);
    ; 2 if it contains something entirely non-text such as a picture.
    try {
        if (type = 1) {
            s := SubStr(A_Clipboard, 1, CharacterCount)
            ToolTip("[INFO] " StrLen(A_Clipboard) " characters copied!`n" s, 0, 0)
            ; Only the shown prefix is archived: the cache is plaintext on disk
            ; and password managers put secrets on the clipboard.  The folder is
            ; only written to when it already exists (it is git-ignored).
            if (s != "" && FileExist(TEXTS_dir))
                FileAppend(s, TEXTS_dir A_Now A_MSec ".txt")
        }
    } catch {
        ToolTip("[ERROR] ")
    }

    SetTimer(CloseToolTip, -800) ; show a ToolTip for at least 800ms
}

CloseToolTip() {
    ToolTip()
}

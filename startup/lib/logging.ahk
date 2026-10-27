; =============================================================================
; logging.ahk -- the one writer for the repository's error.log
; -----------------------------------------------------------------------------
; Every script logs through LogWrite(tag, message):
;
;   * one timestamped line per event, tagged with the writing script;
;   * identical (tag, message) pairs within 5 s are dropped, so an error that
;     repeats on every timer tick cannot flood the file;
;   * the file is rotated to error.old.log once it passes 256 KB.  The check
;     runs on every append, because several scripts write the same file and the
;     manager is not necessarily the one that grows it.
;
; The log lives in the repository root, found from THIS file's location, so the
; path is right no matter which script includes it.
; =============================================================================
LogWrite(tag, message) {
    static logFile := "", oldFile := "", lastKey := "", lastTick := 0

    if (logFile = "") {
        SplitPath(A_LineFile, , &libDir)      ; ...\startup\lib
        SplitPath(libDir, , &startupDir)      ; ...\startup
        SplitPath(startupDir, , &rootDir)     ; repository root
        logFile := rootDir "\error.log"
        oldFile := rootDir "\error.old.log"
    }

    key := tag "|" message
    if (key = lastKey && A_TickCount - lastTick < 5000)
        return
    lastKey := key
    lastTick := A_TickCount

    try {
        if (FileExist(logFile) && FileGetSize(logFile) > 256 * 1024)
            FileMove(logFile, oldFile, 1)
        FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") " " tag ": " message "`n", logFile)
    }
}

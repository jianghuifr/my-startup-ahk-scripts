; =============================================================================
; everything.ahk -- locate Everything.exe on this machine
; -----------------------------------------------------------------------------
; Everything's install path is not fixed: Program Files on most machines, but a
; portable or per-user install lives elsewhere.  Resolve it when a script starts
; instead of hard-coding a path, so the same scripts also work on another
; machine.
;
;   EverythingFindExecutable()   full path of Everything.exe, or "" when
;                                nothing was found (the caller decides what to
;                                tell the user)
;
; Lookup order - first hit wins:
;
;   1. the Windows service "Everything".  Its binary *is* Everything.exe, and
;      its configuration can be queried while the GUI is not even running;
;   2. the install location the installer records in the registry;
;   3. the path of a running Everything process;
;   4. the usual install directories.
; =============================================================================

EverythingFindExecutable() {
    if (exe := EverythingFromService())
        return exe
    if (exe := EverythingFromRegistry())
        return exe
    if (exe := EverythingFromProcess())
        return exe
    return EverythingFromDefaultDirs()
}

; -----------------------------------------------------------------------------
; 1. Windows service "Everything"
; -----------------------------------------------------------------------------
; The service runs the same exe as the GUI, started as "...\Everything.exe"
; -svc, so QueryServiceConfig gives us the install path without guessing.
EverythingFromService() {
    static SC_MANAGER_CONNECT := 0x0001
    static SERVICE_QUERY_CONFIG := 0x0001
    ; QUERY_SERVICE_CONFIGW: lpBinaryPathName follows three DWORDs, aligned to
    ; the pointer size.
    static BINARY_PATH_OFFSET := (A_PtrSize = 8) ? 16 : 12

    hscm := DllCall("advapi32\OpenSCManagerW", "Ptr", 0, "Ptr", 0
                  , "UInt", SC_MANAGER_CONNECT, "Ptr")
    if (!hscm)
        return ""
    try {
        hsvc := DllCall("advapi32\OpenServiceW", "Ptr", hscm, "WStr", "Everything"
                      , "UInt", SERVICE_QUERY_CONFIG, "Ptr")
        if (!hsvc)
            return ""
        try {
            ; The first call only reports the buffer size needed (it fails).
            needed := 0
            DllCall("advapi32\QueryServiceConfigW", "Ptr", hsvc, "Ptr", 0
                  , "UInt", 0, "UInt*", &needed)
            if (!needed)
                return ""
            buf := Buffer(needed, 0)
            if (!DllCall("advapi32\QueryServiceConfigW", "Ptr", hsvc, "Ptr", buf
                       , "UInt", needed, "UInt*", &needed))
                return ""
            if (!(p := NumGet(buf, BINARY_PATH_OFFSET, "Ptr")))
                return ""
            return EverythingExeFromCommandLine(StrGet(p, "UTF-16"))
        } finally {
            DllCall("advapi32\CloseServiceHandle", "Ptr", hsvc)
        }
    } finally {
        DllCall("advapi32\CloseServiceHandle", "Ptr", hscm)
    }
}

; "C:\Program Files\Everything\Everything.exe" -svc  ->  the quoted path
; C:\Tools\Everything.exe -svc                       ->  the first .exe token
EverythingExeFromCommandLine(cmdLine) {
    s := Trim(cmdLine)
    if (SubStr(s, 1, 1) = '"') {
        endQuote := InStr(s, '"', false, 2)
        s := (endQuote > 1) ? SubStr(s, 2, endQuote - 2) : SubStr(s, 2)
    } else if (RegExMatch(s, "(?i)^(.+?\.exe)(?:[ \t]|$)", &m)) {
        s := m[1]
    }
    return FileExist(s) ? s : ""
}

; -----------------------------------------------------------------------------
; 2. Installer's registry entries
; -----------------------------------------------------------------------------
; InstallLocation is a directory, DisplayIcon the exe (sometimes "exe,0"), and
; UninstallString points at Uninstall.exe in the same directory.
EverythingFromRegistry() {
    keys := ["HKLM\SOFTWARE\voidtools\Everything"
           , "HKCU\SOFTWARE\voidtools\Everything"
           , "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Everything"
           , "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Everything"
           , "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Everything"]
    for key in keys {
        for valueName in ["InstallLocation", "DisplayIcon", "UninstallString"] {
            value := ""
            try value := RegRead(key, valueName)
            if (value = "")
                continue
            if (exe := EverythingExeFromKnownPath(value))
                return exe
        }
    }
    return ""
}

; Turn one registry value into the Everything.exe path: the value may be the
; install directory, the exe itself, "exe,0", or another exe in that directory.
EverythingExeFromKnownPath(value) {
    s := Trim(value)
    if (s = "")
        return ""
    if (InStr(s, ","))
        s := Trim(SubStr(s, 1, InStr(s, ",") - 1))   ; "path.exe,0"
    if (SubStr(s, 1, 1) = '"') {
        endQuote := InStr(s, '"', false, 2)
        if (endQuote > 1)
            s := SubStr(s, 2, endQuote - 2)
    }

    type := FileExist(s)
    if (type = "")
        return ""
    if (InStr(type, "D")) {
        dir := RTrim(s, "\")
    } else {
        if (RegExMatch(s, "(?i)\\Everything\.exe$"))
            return s
        SplitPath(s, , &dir)
    }
    exe := dir "\Everything.exe"
    return FileExist(exe) ? exe : ""
}

; -----------------------------------------------------------------------------
; 3. A running Everything process
; -----------------------------------------------------------------------------
; The window's own process first: the service instance runs as SYSTEM and
; cannot be opened without elevation.
EverythingFromProcess() {
    if (hwnd := WinExist("ahk_class EVERYTHING")) {
        try {
            path := ProcessGetPath(WinGetPID("ahk_id " hwnd))
            if (FileExist(path))
                return path
        }
    }
    if (pid := ProcessExist("Everything.exe")) {
        try {
            path := ProcessGetPath(pid)
            if (FileExist(path))
                return path
        }
    }
    return ""
}

; -----------------------------------------------------------------------------
; 4. Usual install locations
; -----------------------------------------------------------------------------
EverythingFromDefaultDirs() {
    for root in [EnvGet("ProgramFiles"), EnvGet("ProgramFiles(x86)")] {
        exe := root "\Everything\Everything.exe"
        if (root != "" && FileExist(exe))
            return exe
    }
    exe := EnvGet("LOCALAPPDATA") "\Programs\Everything\Everything.exe"
    return FileExist(exe) ? exe : ""
}

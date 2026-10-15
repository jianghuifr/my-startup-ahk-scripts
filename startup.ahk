#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

SetWorkingDir(A_ScriptDir)
DetectHiddenWindows(true)
SetTitleMatchMode(2)

StateFile := A_ScriptDir "\state.ini"
LogFile := A_ScriptDir "\error.log"
StartupDir := A_ScriptDir "\startup"

Scripts := []          ; Array of {name, path, submenu, label, menu}
SubMenus := Map()      ; submenu name => array of script indices
Enabled := Map()       ; script path => true/false: what the USER wants running
                       ; (persisted; deliberately not derived from the live state)

; A script with one of these names would collide with our own menu items, so it
; is shown with " (script)" appended.
ReservedNames := Map("Start All", 1, "Stop All", 1, "Restart All", 1
                    , "Open Folder", 1, "Reload", 1, "Rescan Scripts", 1, "Exit", 1)

; ==============================================================================
; Initial launch
; ==============================================================================
DiscoverScripts(StartupDir)
RestoreState()
BuildMenu()

for s in Scripts {
    if Enabled[s.path]
        LaunchScript(s)
}

OnExit(ExitCleanup)
Return

; ==============================================================================
; State persistence
; ------------------------------------------------------------------------------
; Only the user's intent is stored (what was toggled on), never "what happens to
; be running right now". At shutdown the child scripts are already gone when
; this script exits, so deriving the state from the live processes would record
; everything as "off" and nothing would start again after the next boot.
; ==============================================================================
RestoreState() {
    global Scripts, Enabled, StateFile
    hasState := FileExist(StateFile)
    for s in Scripts {
        if (hasState)
            Enabled[s.path] := IniRead(StateFile, "Scripts", s.path, "1") = "1"
        else
            Enabled[s.path] := true
    }
}

SaveState() {
    global Scripts, Enabled, StateFile
    try IniDelete(StateFile, "Scripts")   ; drop stale keys from renamed/removed scripts
    for s in Scripts {
        if (!Enabled.Has(s.path))
            Enabled[s.path] := true
        try IniWrite(Enabled[s.path] ? "1" : "0", StateFile, "Scripts", s.path)
    }
}

; ==============================================================================
; Tray menu
; ------------------------------------------------------------------------------
; AutoHotkey v2 builds (and updates) the Win32 tray menu from the Menu object
; every time the icon is clicked, so there is no need to rebuild it on
; WM_USER+4; the checkmarks are simply refreshed after each toggle.
; ==============================================================================
BuildMenu() {
    global Scripts, SubMenus, StartupDir

    A_TrayMenu.Delete()
    A_IconTip := "AHK Script Manager"

    ; Top-level scripts
    for s in Scripts {
        if (s.submenu != "")
            continue
        s.label := ScriptLabel(s.name)
        s.menu := A_TrayMenu
        A_TrayMenu.Add(s.label, ToggleScript.Bind(s))
    }

    ; Submenu scripts
    for menuName, indices in SubMenus {
        subMenu := Menu()
        for idx in indices {
            s := Scripts[idx]
            s.label := ScriptLabel(s.name)
            s.menu := subMenu
            subMenu.Add(s.label, ToggleScript.Bind(s))
        }
        A_TrayMenu.Add(menuName, subMenu)

        ; Set submenu icon from desktop.ini or default folder icon
        iconFile := ""
        iconIdx := 0
        desktopIni := StartupDir "\" menuName "\desktop.ini"
        if FileExist(desktopIni) {
            iconRes := IniRead(desktopIni, ".ShellClassInfo", "IconResource", "")
            if (iconRes != "") {
                parts := StrSplit(iconRes, ",")
                iconFile := parts[1]
                iconIdx := parts.Length > 1 ? Integer(parts[2]) : 0
            }
        }
        if (iconFile = "") {
            iconFile := "shell32.dll"
            iconIdx := 4
        }
        try A_TrayMenu.SetIcon(menuName, iconFile, iconIdx)
    }

    A_TrayMenu.Add()
    A_TrayMenu.Add("Start All", StartAll)
    A_TrayMenu.Add("Stop All", StopAll)
    A_TrayMenu.Add("Restart All", RestartAll)
    A_TrayMenu.Add("Open Folder", (*) => Run(StartupDir))
    A_TrayMenu.Add()
    A_TrayMenu.Add("Rescan Scripts", RescanScripts)
    A_TrayMenu.Add("Reload", (*) => Reload())
    A_TrayMenu.Add("Exit", MenuExit)

    A_TrayMenu.SetIcon("Start All", "imageres.dll", 102)
    A_TrayMenu.SetIcon("Stop All", "imageres.dll", 101)
    A_TrayMenu.SetIcon("Restart All", "imageres.dll", 229)
    A_TrayMenu.SetIcon("Open Folder", "imageres.dll", 4)
    A_TrayMenu.SetIcon("Rescan Scripts", "imageres.dll", 229)
    A_TrayMenu.SetIcon("Reload", "imageres.dll", 229)
    A_TrayMenu.SetIcon("Exit", "imageres.dll", 85)

    RefreshChecks()
}

ScriptLabel(name) {
    global ReservedNames
    return ReservedNames.Has(name) ? name " (script)" : name
}

RefreshChecks() {
    global Scripts
    for s in Scripts {
        if IsScriptRunning(s.path)
            s.menu.Check(s.label)
        else
            s.menu.Uncheck(s.label)
    }
}

; Re-discover the startup folder (new/removed scripts) without reloading.
; Called from the tray menu, i.e. after the menu has closed.
RescanScripts(*) {
    global Scripts, SubMenus, Enabled, StartupDir
    try {
        Scripts := []
        SubMenus := Map()
        DiscoverScripts(StartupDir)
        for s in Scripts
            if (!Enabled.Has(s.path))
                Enabled[s.path] := true
        BuildMenu()
    } catch as e {
        LogError("Rescan failed: " e.Message)
    }
}

; ==============================================================================
; Script discovery
; ------------------------------------------------------------------------------
; Every subdirectory of startup\ becomes a submenu, except:
;   * lib\            - shared code, never launched
;   * a directory holding a script with exactly the directory's name
;                     - that script is shown as a top-level item (Mask\Mask.ahk)
; ==============================================================================
DiscoverScripts(dir) {
    global Scripts, SubMenus

    subdirs := []
    loop files dir "\*", "D" {
        if (A_LoopFileName = "lib")
            continue
        subdirs.Push(A_LoopFileFullPath)
    }

    for subdir in subdirs {
        SplitPath(subdir, &dirName)
        sameNameScript := subdir "\" dirName ".ahk"
        if FileExist(sameNameScript) {
            AddScript(sameNameScript, "")
        } else {
            loop files subdir "\*.ahk", "F"
                AddScript(A_LoopFileFullPath, dirName)
        }
    }

    loop files dir "\*.ahk", "F"
        AddScript(A_LoopFileFullPath, "")
}

AddScript(fullPath, submenu) {
    global Scripts, SubMenus
    SplitPath(fullPath, , , , &nameNoExt)
    Scripts.Push({name: nameNoExt, path: fullPath, submenu: submenu})
    if (submenu != "") {
        if !SubMenus.Has(submenu)
            SubMenus[submenu] := []
        SubMenus[submenu].Push(Scripts.Length)
    }
}

; ==============================================================================
; Check if a script is running (by window title)
; ==============================================================================
IsScriptRunning(scriptPath) {
    return WinExist(scriptPath " ahk_class AutoHotkey") ? true : false
}

; ==============================================================================
; Launch / Kill
; ==============================================================================
LaunchScript(s) {
    if IsScriptRunning(s.path)
        return
    SplitPath(s.path, , &dir, , &nameNoExt)
    cliFile := dir "\" nameNoExt ".cli"
    params := ""
    try {
        if FileExist(cliFile)
            params := Trim(StrSplit(FileRead(cliFile) "`n", "`n")[1])
        ; Start through the interpreter that runs this manager: relying on the
        ; .ahk file association could pick AutoHotkey v1 and only pop an error.
        Run('"' A_AhkPath '" "' s.path '"' (params = "" ? "" : " " params), dir)
    } catch as e {
        LogError("Launch failed: " s.path " - " e.Message)
    }
}

KillScript(s) {
    hwnd := WinExist(s.path " ahk_class AutoHotkey")
    if (hwnd)
        WinClose("ahk_id " hwnd)
}

; ==============================================================================
; Menu handlers
; ==============================================================================
ToggleScript(s, *) {
    global Enabled
    if IsScriptRunning(s.path) {
        KillScript(s)
        Enabled[s.path] := false
    } else {
        LaunchScript(s)
        Enabled[s.path] := true
    }
    SaveState()
    RefreshChecks()
}

StartAll(*) {
    global Scripts, Enabled
    for s in Scripts {
        LaunchScript(s)
        Enabled[s.path] := true
    }
    SaveState()
    RefreshChecks()
}

StopAll(*) {
    global Scripts, Enabled
    for s in Scripts {
        KillScript(s)
        Enabled[s.path] := false
    }
    SaveState()
    RefreshChecks()
}

; Restart every script: stop all, wait for their windows to close, then start.
; Handy after editing scripts, since #SingleInstance Force means a fresh launch
; replaces the old instance.
RestartAll(*) {
    global Scripts
    StopAll()
    ; wait until running scripts have actually exited (up to ~2s)
    Loop 20 {
        anyRunning := false
        for s in Scripts {
            if IsScriptRunning(s.path) {
                anyRunning := true
                break
            }
        }
        if (!anyRunning)
            break
        Sleep(100)
    }
    StartAll()
}

MenuExit(*) {
    ExitApp()
}

; ==============================================================================
; Cleanup on exit
; ==============================================================================
ExitCleanup(reason, code) {
    SaveState()
    LogError("Exit reason: " reason " code: " code)
}

LogError(message) {
    global LogFile
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") " " message "`n", LogFile)
}

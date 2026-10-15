#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

SetWorkingDir(A_ScriptDir)
DetectHiddenWindows(true)
SetTitleMatchMode(2)

StateFile := A_ScriptDir "\state.ini"
StartupDir := A_ScriptDir "\startup"
ExcludeScripts := []

Scripts := []          ; Array of {name, path, submenu}
SubMenus := Map()     ; submenu name => array of script indices
SubMenuObjs := Map()  ; submenu name => Menu object

; ==============================================================================
; Initial launch
; ==============================================================================
DiscoverScripts(StartupDir)
BuildMenu()

; Restore state
hasState := FileExist(StateFile)
for s in Scripts {
    if (hasState) {
        lastState := IniRead(StateFile, "Scripts", s.path, "1")
        if (lastState = "1")
            LaunchScript(s)
    } else {
        LaunchScript(s)
    }
}

; Rebuild menu on tray icon right-click (before menu shows)
OnMessage(0x0404, OnTrayClick)

OnTrayClick(wParam, lParam, *) {
    if (lParam = 0x0205)  ; WM_RBUTTONUP
        RebuildMenu()
}

OnExit(ExitCleanup)
Return

; ==============================================================================
; Rebuild: re-discover scripts and rebuild menu (called on menu open)
; ==============================================================================
RebuildMenu() {
    global Scripts, SubMenus, SubMenuObjs
    try {
        Scripts := []
        SubMenus := Map()
        SubMenuObjs := Map()
        DiscoverScripts(StartupDir)
        BuildMenu()
    } catch as e {
        FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") " RebuildMenu error: " e.Message "`n", A_ScriptDir "\error.log")
    }
}

; ==============================================================================
; Build tray menu from current Scripts array
; ==============================================================================
BuildMenu() {
    global Scripts, SubMenus, SubMenuObjs, StartupDir

    A_TrayMenu.Delete()
    A_IconTip := "AHK Script Manager"

    ; Top-level scripts
    for s in Scripts {
        if (s.submenu = "") {
            A_TrayMenu.Add(s.name, ToggleScript)
            if IsScriptRunning(s.path)
                A_TrayMenu.Check(s.name)
        }
    }

    ; Submenu scripts
    for menuName, indices in SubMenus {
        subMenu := Menu()
        for idx in indices {
            s := Scripts[idx]
            subMenu.Add(s.name, ToggleScript)
            if IsScriptRunning(s.path)
                subMenu.Check(s.name)
        }
        SubMenuObjs[menuName] := subMenu
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
    A_TrayMenu.Add("Reload", (*) => Reload())
    A_TrayMenu.Add("Exit", MenuExit)

    A_TrayMenu.SetIcon("Start All", "imageres.dll", 102)
    A_TrayMenu.SetIcon("Stop All", "imageres.dll", 101)
    A_TrayMenu.SetIcon("Restart All", "imageres.dll", 229)
    A_TrayMenu.SetIcon("Open Folder", "imageres.dll", 4)
    A_TrayMenu.SetIcon("Reload", "imageres.dll", 229)
    A_TrayMenu.SetIcon("Exit", "imageres.dll", 85)
}

; ==============================================================================
; Script discovery
; ==============================================================================
DiscoverScripts(dir) {
    global Scripts, ExcludeScripts, StartupDir, SubMenus

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
            ; Single same-name script -> top-level menu item
            AddScript(sameNameScript, "")
        } else {
            loop files subdir "\*.ahk", "F" {
                if HasVal(ExcludeScripts, A_LoopFileName)
                    continue
                AddScript(A_LoopFileFullPath, dirName)
            }
        }
    }

    loop files dir "\*.ahk", "F" {
        if HasVal(ExcludeScripts, A_LoopFileName)
            continue
        AddScript(A_LoopFileFullPath, "")
    }
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
    try {
        if FileExist(cliFile) {
            params := Trim(StrSplit(FileRead(cliFile), "`n")[1])
            Run(s.path ' ' params, dir)
        } else {
            Run(s.path, dir)
        }
    } catch as e {
        FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") " Launch failed: " s.path " - " e.Message "`n", A_ScriptDir "\error.log")
    }
}

KillScript(s) {
    hwnd := WinExist(s.path " ahk_class AutoHotkey")
    if (hwnd)
        WinClose()
}

; ==============================================================================
; Menu handlers
; ==============================================================================
ToggleScript(name, *) {
    global Scripts
    for s in Scripts {
        if (s.name = name) {
            if IsScriptRunning(s.path)
                KillScript(s)
            else
                LaunchScript(s)
            return
        }
    }
}

StartAll(*) {
    global Scripts
    for s in Scripts
        LaunchScript(s)
}

StopAll(*) {
    global Scripts
    for s in Scripts
        KillScript(s)
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
; State persistence (keyed by full path)
; ==============================================================================
SaveState() {
    global Scripts, StateFile
    try IniDelete(StateFile, "Scripts")  ; drop stale keys from renamed/moved scripts
    for s in Scripts {
        state := IsScriptRunning(s.path) ? "1" : "0"
        IniWrite(state, StateFile, "Scripts", s.path)
    }
}

; ==============================================================================
; Cleanup on exit
; ==============================================================================
ExitCleanup(reason, code) {
    FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") " Exit reason: " reason " code: " code "`n", A_ScriptDir "\error.log")
    SaveState()
}

; ==============================================================================
; Utility
; ==============================================================================
HasVal(arr, val) {
    for v in arr
        if (v = val)
            return true
    return false
}

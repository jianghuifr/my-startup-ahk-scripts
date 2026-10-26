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
ManageMenu := 0        ; the "All scripts" submenu, kept so it can be greyed out

; A script with one of these names would collide with our own menu items, so it
; is shown with " (script)" appended.
ReservedNames := Map("Start All", 1, "Stop All", 1, "Restart All", 1
                    , "All scripts", 1, "Open Folder", 1, "Reload", 1, "Exit", 1)

; ==============================================================================
; Initial launch
; ==============================================================================
DiscoverScripts(StartupDir)
RestoreState()
BuildMenu()

; The Win32 tray menu is only built when the icon is clicked, so without this
; the checkmarks would go stale the moment a script starts or stops on its own
; (crash, manual launch, another session). A slow poll is enough.
SetTimer(RefreshChecks, 2000)

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
    global Scripts, SubMenus, StartupDir, ManageMenu

    A_TrayMenu.Delete()

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

        ; Folder icon for the submenu.  (The old per-folder desktop.ini lookup
        ; was never used: no startup subfolder ships one.)
        try A_TrayMenu.SetIcon(menuName, "shell32.dll", 4)
    }

    ; Footer.  The bulk actions are one hover away instead of three separate
    ; entries, and "Rescan Scripts" is gone: reloading the manager re-discovers
    ; the startup folder anyway, so one Reload does both.
    A_TrayMenu.Add()

    bulk := Menu()
    bulk.Add("Start All", StartAll)
    bulk.Add("Stop All", StopAll)
    bulk.Add("Restart All", RestartAll)
    bulk.SetIcon("Start All", "imageres.dll", 102)
    bulk.SetIcon("Stop All", "imageres.dll", 101)
    bulk.SetIcon("Restart All", "imageres.dll", 229)
    A_TrayMenu.Add("All scripts", bulk)
    ManageMenu := bulk

    A_TrayMenu.Add("Open Folder", (*) => Run(StartupDir))
    A_TrayMenu.Add()
    A_TrayMenu.Add("Reload", (*) => Reload())
    A_TrayMenu.Add("Exit", MenuExit)

    A_TrayMenu.SetIcon("All scripts", "shell32.dll", 4)
    A_TrayMenu.SetIcon("Open Folder", "imageres.dll", 4)
    A_TrayMenu.SetIcon("Reload", "imageres.dll", 229)
    A_TrayMenu.SetIcon("Exit", "imageres.dll", 85)

    RefreshChecks()
}

ScriptLabel(name) {
    global ReservedNames
    return ReservedNames.Has(name) ? name " (script)" : name
}

RefreshChecks() {
    global Scripts, ManageMenu

    running := 0
    for s in Scripts {
        if IsScriptRunning(s.path) {
            s.menu.Check(s.label)
            running++
        } else
            s.menu.Uncheck(s.label)
    }

    ; Grey out the bulk action that would do nothing, and put the tally in the
    ; tray tooltip so the state is readable without opening the menu at all.
    if (ManageMenu) {
        if (running = Scripts.Length)
            ManageMenu.Disable("Start All")
        else
            ManageMenu.Enable("Start All")
        if (running = 0)
            ManageMenu.Disable("Stop All")
        else
            ManageMenu.Enable("Stop All")
    }
    A_IconTip := "AHK Script Manager - " running "/" Scripts.Length " running"
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
    SplitPath(s.path, , &dir)
    try {
        ; Start through the interpreter that runs this manager: relying on the
        ; .ahk file association could pick AutoHotkey v1 and only pop an error.
        Run('"' A_AhkPath '" "' s.path '"', dir)
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

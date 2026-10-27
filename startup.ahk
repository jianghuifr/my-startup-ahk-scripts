#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

SetWorkingDir(A_ScriptDir)
DetectHiddenWindows(true)
SetTitleMatchMode(2)

#Include %A_ScriptDir%\startup\lib\logging.ahk

StateFile := A_ScriptDir "\state.ini"
StartupDir := A_ScriptDir "\startup"

Scripts := []          ; Array of {name, path, submenu, label, menu} +
                       ; runtime state {running, stuck, launchTick}
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

for s in Scripts {
    if Enabled[s.path]
        LaunchScript(s)
}

; BuildMenu() painted the checkmarks before anything was started; refresh once so
; the menu is correct immediately instead of waiting for the first timer tick.
RefreshChecks()

; The Win32 tray menu is only built when the icon is clicked, so without this
; the checkmarks would go stale the moment a script starts or stops on its own
; (crash, manual launch, another session). A slow poll is enough.  It is started
; after the launch loop so no timer can fire before OnError is installed below.
SetTimer(RefreshChecks, 2000)

OnExit(ExitCleanup)

; A timer or menu thread that throws would otherwise raise a modal dialog, which
; freezes the tray until it is dismissed.  Log it and let the next tick retry.
OnError(LogUncaught)

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
        value := ""
        if (hasState) {
            ; Paths are stored relative to startup\, so the file survives moving
            ; or copying the repository.  Older state files used absolute paths;
            ; read those too, and the next save migrates the file.
            value := IniRead(StateFile, "Scripts", StateKey(s.path), "")
            if (value = "")
                value := IniRead(StateFile, "Scripts", s.path, "")
        }
        Enabled[s.path] := (value = "") ? true : (value = "1")
    }
}

SaveState() {
    global Scripts, Enabled, StateFile
    text := "; Paths are relative to the startup folder.`n[Scripts]`n"
    for s in Scripts {
        if (!Enabled.Has(s.path))
            Enabled[s.path] := true
        text .= StateKey(s.path) "=" (Enabled[s.path] ? "1" : "0") "`n"
    }
    ; One write through a temporary file: a crash while saving must not truncate
    ; the state, and rewriting the file also drops renamed/removed scripts.
    tmp := StateFile ".tmp"
    try {
        f := FileOpen(tmp, "w", "UTF-8")
        f.Write(text)
        f.Close()
        FileMove(tmp, StateFile, 1)
    } catch as e {
        LogError("Could not save the state: " e.Message)
        try FileDelete(tmp)
    }
}

; Key used in state.ini: the script path relative to the startup folder.
StateKey(scriptPath) {
    global StartupDir
    prefix := StartupDir "\"
    if (SubStr(scriptPath, 1, StrLen(prefix)) = prefix)
        return SubStr(scriptPath, StrLen(prefix) + 1)
    return scriptPath
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
    global Scripts, Enabled, ManageMenu

    ; One enumeration of the AHK main windows instead of one window search per
    ; script.  Each script's main window title is "<full script path> - AutoHotkey
    ; vX.Y.Z", however the script was started.
    runningPid := Map()
    for hwnd in WinGetList("ahk_class AutoHotkey") {
        ; The window can be destroyed between the enumeration and these calls.
        ; That race is expected, so it is handled quietly here.
        try {
            title := WinGetTitle("ahk_id " hwnd)
            pid := WinGetPID("ahk_id " hwnd)
        } catch {
            continue
        }
        for s in Scripts {
            if (!runningPid.Has(s.path) && InStr(title, s.path))
                runningPid[s.path] := pid
        }
    }

    ; A script waiting on a visible dialog (its own MsgBox, an unhandled error,
    ; ...) still runs, but is stuck; note the processes that show one.
    dialogPid := Map()
    for hwnd in WinGetList("ahk_class #32770") {
        if (DllCall("IsWindowVisible", "Ptr", hwnd)) {
            try dialogPid[WinGetPID("ahk_id " hwnd)] := true
        }
    }

    running := 0
    stuck := 0
    for s in Scripts {
        isRunning := runningPid.Has(s.path)

        ; Launched but never came up (syntax error, ...), or disappeared although
        ; the user wants it on (crash, killed from outside).  Not logged for a
        ; script we are closing ourselves: ToggleScript/StopAll clear Enabled
        ; first.
        if (s.launchTick) {
            if (isRunning)
                s.launchTick := 0
            else if (A_TickCount - s.launchTick > 1500) {
                s.launchTick := 0
                LogError("Script did not start: " s.path)
            }
        } else if (s.running && !isRunning && Enabled[s.path]) {
            LogError("Script stopped unexpectedly: " s.path)
        }
        s.running := isRunning

        isStuck := isRunning && dialogPid.Has(runningPid[s.path])
        if (isStuck && !s.stuck)
            LogError("Script is waiting on a dialog: " s.path)
        s.stuck := isStuck

        if (isRunning) {
            s.menu.Check(s.label)
            running++
            if (isStuck)
                stuck++
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
    tip := "AHK Script Manager - " running "/" Scripts.Length " running"
    if (stuck)
        tip .= ", " stuck " waiting on a dialog"
    if (A_IconTip != tip)
        A_IconTip := tip
}

; ==============================================================================
; Script discovery
; ------------------------------------------------------------------------------
; Every subdirectory of startup\ becomes a submenu, except:
;   * lib\            - shared code, never launched
;   * a directory holding a script with exactly the directory's name
;                     - that script is shown as a top-level item (Mask\Mask.ahk)
; Entries are sorted, so the menu and the startup order do not depend on the
; order the file system happens to return.
; ==============================================================================
DiscoverScripts(dir) {
    global Scripts, SubMenus

    subdirs := []
    loop files dir "\*", "D" {
        if (A_LoopFileName = "lib")
            continue
        subdirs.Push(A_LoopFileFullPath)
    }
    SortStrings(subdirs)

    for subdir in subdirs {
        SplitPath(subdir, &dirName)
        sameNameScript := subdir "\" dirName ".ahk"
        if FileExist(sameNameScript) {
            AddScript(sameNameScript, "")
            WarnIgnoredScripts(subdir, dirName, sameNameScript)
            continue
        }
        files := []
        loop files subdir "\*.ahk", "F"
            files.Push(A_LoopFileFullPath)
        SortStrings(files)
        for file in files
            AddScript(file, dirName)
    }

    files := []
    loop files dir "\*.ahk", "F"
        files.Push(A_LoopFileFullPath)
    SortStrings(files)
    for file in files
        AddScript(file, "")
}

; A folder that names one script is launched with only that script.  Other .ahk
; files there are usually #Include'd supporting code (win.ahk, gdip.ahk next to
; WinAlwaysOnTop.ahk); anything neither included nor launched is likely a
; mistake and would otherwise just be silently missing from the tray menu.
WarnIgnoredScripts(dir, dirName, mainScript) {
    try source := FileRead(mainScript)
    catch
        return
    ignored := []
    loop files dir "\*.ahk", "F" {
        name := A_LoopFileName
        if (name = dirName ".ahk")
            continue
        if (InStr(source, name))        ; used as an include by the folder's script
            continue
        ignored.Push(name)
    }
    if (ignored.Length)
        LogError("Discovery: not launching " JoinStrings(ignored, ", ")
               . " in " dirName "\ (only " dirName ".ahk is used there)")
}

JoinStrings(arr, sep) {
    s := ""
    for v in arr
        s .= (s = "" ? "" : sep) v
    return s
}

; Case-insensitive insertion sort; an AHK v2 Array has no Sort method.
SortStrings(arr) {
    n := arr.Length
    loop n - 1 {
        i := A_Index
        item := arr[i + 1]
        j := i
        while (j >= 1 && StrCompare(StrLower(arr[j]), StrLower(item)) > 0) {
            arr[j + 1] := arr[j]
            j -= 1
        }
        arr[j + 1] := item
    }
}

AddScript(fullPath, submenu) {
    global Scripts, SubMenus
    SplitPath(fullPath, , , , &nameNoExt)
    Scripts.Push({name: nameNoExt, path: fullPath, submenu: submenu
                , running: false, stuck: false, launchTick: 0})
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
        s.launchTick := A_TickCount   ; RefreshChecks verifies it actually came up
    } catch as e {
        LogError("Launch failed: " s.path " - " e.Message)
    }
}

; Close a script without waiting; StopAll() closes the whole batch and waits once.
CloseScript(s) {
    hwnd := WinExist(s.path " ahk_class AutoHotkey")
    if (hwnd)
        WinClose("ahk_id " hwnd)
}

; Close one script and wait for it to leave, so the state saved right afterwards
; does not say "off" while the process is still alive.  The wait is normally a
; few dozen milliseconds; one second is the point where something is wrong.
KillScript(s) {
    if (!WinExist(s.path " ahk_class AutoHotkey"))
        return true
    CloseScript(s)
    Loop 40 {          ; up to 1 s, polling every 25 ms
        Sleep(25)
        if (!WinExist(s.path " ahk_class AutoHotkey"))
            return true
    }
    LogError("Script did not close within 1 s: " s.path)
    return false
}

; Wait until no script is running any more, up to timeoutMs; returns the paths
; that are still alive.  One shared deadline instead of one wait per script.
WaitScriptsClosed(timeoutMs) {
    global Scripts
    deadline := A_TickCount + timeoutMs
    while (A_TickCount < deadline) {
        any := false
        for s in Scripts {
            if (WinExist(s.path " ahk_class AutoHotkey")) {
                any := true
                break
            }
        }
        if (!any)
            return []
        Sleep(25)
    }
    still := []
    for s in Scripts
        if (WinExist(s.path " ahk_class AutoHotkey"))
            still.Push(s.path)
    return still
}

; ==============================================================================
; Menu handlers
; ==============================================================================
ToggleScript(s, *) {
    global Enabled
    if IsScriptRunning(s.path) {
        ; Set the intent before closing, so the refresh that runs while OnExit is
        ; still finishing does not report "stopped unexpectedly".
        Enabled[s.path] := false
        KillScript(s)
    } else {
        Enabled[s.path] := true
        LaunchScript(s)
    }
    SaveState()
    RefreshSoon()   ; the process needs a moment to appear/disappear
}

StartAll(*) {
    global Scripts, Enabled
    for s in Scripts
        Enabled[s.path] := true
    for s in Scripts
        LaunchScript(s)
    SaveState()
    RefreshSoon(600)   ; give the windows a moment to appear
}

StopAll(*) {
    global Scripts, Enabled
    for s in Scripts
        Enabled[s.path] := false
    ; Close every script first, then wait for the batch with one deadline: a
    ; wedged script costs one second in total instead of one second each.
    for s in Scripts
        CloseScript(s)
    for path in WaitScriptsClosed(1200)
        LogError("Script did not close within 1.2 s: " path)
    SaveState()
    RefreshSoon()
}

; One-shot refresh after a launch/kill: a timer with a different callback than
; the periodic RefreshChecks, so it does not replace it.
RefreshSoon(delay := 300) {
    SetTimer(RefreshSoonRun, -delay)
}

RefreshSoonRun() {
    RefreshChecks()
}

; Stop everything, wait for the batch, then start it again; handy after editing
; scripts, since #SingleInstance Force means a fresh launch replaces the old one.
RestartAll(*) {
    StopAll()   ; closes everything and waits once for the whole batch
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
    ; Clean exits (Close, menu Exit, reload, shutdown) are not worth a log line.
    if (reason = "Error" || reason = "Critical")
        LogError("Exit reason: " reason " code: " code)
}

LogError(message) {
    LogWrite("Manager", message)
}

; OnError handler: log the uncaught error instead of raising the modal dialog.
; Returning 1 suppresses the default error dialog.
LogUncaught(err, mode) {
    text := err.Message
    if (err.HasProp("File") && err.File != "")
        text .= " (" err.File ":" err.Line ")"
    LogError("Uncaught error: " text)
    return 1
}

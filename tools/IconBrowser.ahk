#Requires AutoHotkey v2.0
#SingleInstance Force

; Usage: pass DLL name as first arg (default imageres.dll), count as second (default 320)
dllName := A_Args.Length >= 1 ? A_Args[1] : "imageres.dll"
count := A_Args.Length >= 2 ? Integer(A_Args[2]) : 320

myGui := Gui("+Resize", dllName " Icons")
myGui.Add("Text", , dllName " icons (index 1-" count "):")
LV := myGui.Add("ListView", "w800 h600 Icon", ["Name"])

ImageListID := IL_Create(count, 1, 1)
LV.SetImageList(ImageListID)

Loop count {
    IL_Add(ImageListID, dllName, A_Index)
    LV.Add("Icon" A_Index, "Icon " A_Index)
}

myGui.OnEvent("Close", (*) => ExitApp())
myGui.Show("w820 h650")

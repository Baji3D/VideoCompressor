' Starts compress.ps1 with no console window flashing. Used by the right-click menu.
Dim fso, dir, cmd, i
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\compress.ps1"""
For i = 0 To WScript.Arguments.Count - 1
    cmd = cmd & " """ & WScript.Arguments(i) & """"
Next
CreateObject("WScript.Shell").Run cmd, 0, False

Option Explicit

Dim shell, fso, scriptDir, powershellPath, guiPath, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
guiPath = fso.BuildPath(scriptDir, "claude-switcher-gui.ps1")

If Not fso.FileExists(guiPath) Then
    MsgBox "Cannot find claude-switcher-gui.ps1 next to this launcher.", vbCritical, "Claude Switcher"
    WScript.Quit 1
End If

command = Chr(34) & powershellPath & Chr(34) & " -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File " & Chr(34) & guiPath & Chr(34)
shell.Run command, 0, False

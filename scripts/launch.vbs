' Runs Launch-Claude.ps1 fully hidden (no PowerShell console flash).
' The .ps1 is expected to live next to this .vbs file.
'
' Usage:  wscript.exe launch.vbs "<profile-data-dir>" ["<claude-config-dir>"]
'         The optional 2nd argument isolates Claude Code / Cowork memory via
'         CLAUDE_CONFIG_DIR.

Set args = WScript.Arguments
If args.Count < 1 Then
    WScript.Echo "Usage: launch.vbs ""<profile-data-dir>"" [""<claude-config-dir>""]"
    WScript.Quit 1
End If

profileDir = args(0)

Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = fso.BuildPath(scriptDir, "Launch-Claude.ps1")

Set sh = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """ -ProfileDir """ & profileDir & """"
If args.Count >= 2 Then
    cmd = cmd & " -ConfigDir """ & args(1) & """"
End If

' 0 = hidden window, False = don't wait.
sh.Run cmd, 0, False

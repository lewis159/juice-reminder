' Launches the juice reminder with no console window visible.
' Any arguments (e.g. -Settings) are passed through to JuiceReminder.ps1.
Dim shell, here, args, a
Set shell = CreateObject("WScript.Shell")
here = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
args = ""
For Each a In WScript.Arguments
    args = args & " " & a
Next
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & here & "JuiceReminder.ps1""" & args, 0, False

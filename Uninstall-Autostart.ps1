# Removes the Startup-folder shortcut and stops any running copy.
$linkPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Juice Reminder.lnk'
if (Test-Path $linkPath) { Remove-Item $linkPath; Write-Host "Removed: $linkPath" }
else { Write-Host "No autostart shortcut found." }

# Match only processes actually running the script, never a shell that merely
# mentions the filename (and never this process).
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*-File *JuiceReminder.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host "Stopped running reminder (PID $($_.ProcessId))." }

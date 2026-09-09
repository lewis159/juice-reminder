# Removes the Startup-folder shortcut and stops any running copy.
$linkPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Juice Reminder.lnk'
if (Test-Path $linkPath) { Remove-Item $linkPath; Write-Host "Removed: $linkPath" }
else { Write-Host "No autostart shortcut found." }

Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like '*JuiceReminder.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host "Stopped running reminder (PID $($_.ProcessId))." }

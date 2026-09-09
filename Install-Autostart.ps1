# Adds (or refreshes) a Startup-folder shortcut so the reminder runs at every login.
$here     = Split-Path -Parent $MyInvocation.MyCommand.Definition
$startup  = [Environment]::GetFolderPath('Startup')
$linkPath = Join-Path $startup 'Juice Reminder.lnk'

$shell = New-Object -ComObject WScript.Shell
$link  = $shell.CreateShortcut($linkPath)
$link.TargetPath       = 'wscript.exe'
$link.Arguments        = '"' + (Join-Path $here 'Start-JuiceReminder.vbs') + '"'
$link.WorkingDirectory = $here
$link.Description      = 'Hourly reminder to drink your juice'
$link.Save()

Write-Host "Installed: $linkPath"
Write-Host "It will start automatically next time you log in."

<#
    Called by the Juice Reminder installer and uninstaller; not meant to be run by hand.

      -Action Install    Stops any running reminder, then silently removes leftovers
                         of the old script-based install (Install-Autostart.ps1):
                         Startup shortcuts that launch the reminder from anywhere
                         other than the install folder.
      -Action Uninstall  Stops any running reminder.

    Everything it does goes to the reminder's log. It always exits 0, so a cleanup
    hiccup can never block setup.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Install', 'Uninstall')]
    [string]$Action,

    [Parameter(Mandatory)]
    [string]$InstallDir,

    [string]$Version = '',

    [string]$LogDir = 'C:\JuiceReminder\logs'
)

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )

    try {
        if (-not (Test-Path $LogDir)) {
            New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        }
        $path = Join-Path $LogDir 'juice-reminder.log'
        if ((Test-Path $path) -and (Get-Item $path).Length -ge 1MB) {
            Move-Item -Path $path -Destination "$path.1" -Force
        }
        $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] [setup] {2}' -f (Get-Date), $Level, $Message
        Add-Content -Path $path -Value $line -Encoding UTF8
    }
    catch { }
}

function Test-UnderInstallDir {
    param([string]$Path)

    if (-not $Path) { return $false }
    try {
        $root = [System.IO.Path]::GetFullPath($InstallDir).TrimEnd('\') + '\'
        $full = [System.IO.Path]::GetFullPath($Path)
    }
    catch { return $false }
    return $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-ReminderScriptPath {
    <#
        Returns the JuiceReminder.ps1 path a powershell.exe command line is running
        via -File, or $null. The path must be a real file: a shell whose command
        text merely contains the pattern (e.g. '-like "*-File *JuiceReminder.ps1*"')
        yields a wildcard or fragment that does not exist, and is left alone.
    #>
    param([string]$CommandLine)

    if (-not $CommandLine) { return $null }
    if ($CommandLine -notmatch '(?i)\s-File\s+(?:"([^"]+)"|(\S+))') { return $null }

    $path = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
    if ((Split-Path -Leaf $path) -ne 'JuiceReminder.ps1') { return $null }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    return $path
}

function Stop-RunningReminders {
    $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.ProcessId -ne $PID -and (Get-ReminderScriptPath $_.CommandLine) })

    if ($procs.Count -eq 0) {
        Write-Log 'No running reminder found.'
        return
    }

    foreach ($proc in $procs) {
        $script = Get-ReminderScriptPath $proc.CommandLine
        $kind   = if (Test-UnderInstallDir $script) { 'installed copy' } else { 'old script-install copy' }

        try {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
            Write-Log "Stopped $kind (PID $($proc.ProcessId)): $script"
        }
        catch {
            Write-Log "Could not stop PID $($proc.ProcessId): $($_.Exception.Message)" 'WARN'
        }
    }
}

function Remove-LegacyStartupShortcuts {
    $startup = [Environment]::GetFolderPath('Startup')
    $shell   = New-Object -ComObject WScript.Shell
    $removed = 0

    foreach ($lnk in @(Get-ChildItem -Path $startup -Filter '*.lnk' -ErrorAction SilentlyContinue)) {
        $shortcut = $shell.CreateShortcut($lnk.FullName)
        $command  = "$($shortcut.TargetPath) $($shortcut.Arguments)"
        if ($command -notmatch 'Start-JuiceReminder\.vbs|JuiceReminder\.ps1') { continue }

        $launches = $shortcut.TargetPath
        if ($shortcut.Arguments -match '"?([^"]*(Start-JuiceReminder\.vbs|JuiceReminder\.ps1))') {
            $launches = $Matches[1].Trim()
        }

        # A shortcut into the install folder belongs to this installer; leave it.
        if (Test-UnderInstallDir $launches) { continue }

        try {
            Remove-Item -LiteralPath $lnk.FullName -Force -ErrorAction Stop
            Write-Log "Removed old script-install Startup shortcut '$($lnk.Name)' (launched $launches)."
            $removed++
        }
        catch {
            Write-Log "Could not remove '$($lnk.FullName)': $($_.Exception.Message)" 'WARN'
        }
    }

    if ($removed -eq 0) { Write-Log 'No old script-install Startup shortcuts found.' }
}

try {
    $label = if ($Version) { "$Action v$Version" } else { $Action }
    Write-Log "$label started. Install folder: $InstallDir"

    Stop-RunningReminders
    if ($Action -eq 'Install') { Remove-LegacyStartupShortcuts }

    Write-Log "$label cleanup finished."
}
catch {
    Write-Log "Cleanup failed: $($_.Exception.Message)" 'ERROR'
}

exit 0

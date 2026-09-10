<#
    Regenerates the icon and compiles dist\JuiceReminderSetup.exe with Inno Setup.

    Inno Setup 6 is required:  winget install --id JRSoftware.InnoSetup
#>

[CmdletBinding()]
param(
    # Path to ISCC.exe, if it is not in one of the usual places.
    [string]$Iscc
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

if (-not $Iscc) {
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
    )
    $Iscc = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $Iscc) {
    throw "ISCC.exe not found. Install Inno Setup 6 (winget install --id JRSoftware.InnoSetup) or pass -Iscc."
}

& (Join-Path $root 'tools\New-JuiceIcon.ps1')

& $Iscc (Join-Path $root 'installer\JuiceReminder.iss')
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE." }

$setup = Join-Path $root 'dist\JuiceReminderSetup.exe'
Write-Host ""
Write-Host "Built $setup ($([math]::Round((Get-Item $setup).Length / 1MB, 2)) MB)"

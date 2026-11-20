<#
    Regenerates the icon and compiles dist\JuiceReminderSetup.exe with Inno Setup.
    The installer version is read from $AppVersion in JuiceReminder.ps1.

    Inno Setup 6 is required:  winget install --id JRSoftware.InnoSetup
#>

[CmdletBinding()]
param(
    # Path to ISCC.exe, if it is not in one of the usual places.
    [string]$Iscc,

    # Short release notes for dist\latest.json (shown nowhere yet; kept for later).
    [string]$Notes = '',

    # GitHub repo the release is published to; used for the download URL in latest.json.
    [string]$Repo = 'lewis159/juice-reminder'
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

$scriptText = Get-Content -Raw -Path (Join-Path $root 'JuiceReminder.ps1')
if ($scriptText -notmatch "\`$AppVersion\s*=\s*'([^']+)'") {
    throw "Could not find `$AppVersion = '...' in JuiceReminder.ps1."
}
$version = $Matches[1]

& (Join-Path $root 'tools\New-JuiceIcon.ps1')

& $Iscc "/DAppVersion=$version" (Join-Path $root 'installer\JuiceReminder.iss')
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE." }

$setup = Join-Path $root 'dist\JuiceReminderSetup.exe'
$hash  = (Get-FileHash $setup -Algorithm SHA256).Hash

# Update manifest the app reads from releases/latest/download/latest.json.
# Upload it to the same release as the installer.
$manifest = [ordered]@{
    version   = $version
    url       = "https://github.com/$Repo/releases/download/v$version/JuiceReminderSetup.exe"
    sha256    = $hash
    notes     = $Notes
    published = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}
$manifestPath = Join-Path $root 'dist\latest.json'
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))

Write-Host ""
Write-Host "Built $setup v$version ($([math]::Round((Get-Item $setup).Length / 1MB, 2)) MB)"
Write-Host "SHA-256 $hash"
Write-Host "Wrote $manifestPath"
Write-Host "Release: gh release create v$version dist\JuiceReminderSetup.exe dist\latest.json"

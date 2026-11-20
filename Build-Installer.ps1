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
    [string]$Repo = 'lewis159/juice-reminder',

    # Code-signing certificate in Cert:\CurrentUser\My (see tools\New-SigningCert.ps1).
    # Must be one of $TrustedSignerThumbprints in JuiceReminder.ps1, or installed
    # copies will refuse the update.
    [string]$SigningThumbprint = '4D1E8C6F2D423271B9A0E70A3127F38A353C63B2',

    # Build without signing (local testing only; never release an unsigned build).
    [switch]$AllowUnsigned
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

# Sign before hashing: the signature is part of the file.
$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Where-Object { $_.Thumbprint -eq $SigningThumbprint }
if ($cert) {
    $signed = $null
    foreach ($ts in @('http://timestamp.digicert.com', 'http://timestamp.sectigo.com')) {
        try {
            $signed = Set-AuthenticodeSignature -FilePath $setup -Certificate $cert -HashAlgorithm SHA256 -TimestampServer $ts -ErrorAction Stop
            if ($signed.SignerCertificate) { break }
        }
        catch { Write-Warning "Timestamp server $ts failed: $($_.Exception.Message)" }
    }
    if (-not $signed -or -not $signed.SignerCertificate) {
        Write-Warning 'No timestamp server answered; signing without a timestamp (still fine until the certificate expires).'
        $signed = Set-AuthenticodeSignature -FilePath $setup -Certificate $cert -HashAlgorithm SHA256
    }
    $check = Get-AuthenticodeSignature -FilePath $setup
    if ($check.SignerCertificate.Thumbprint -ne $SigningThumbprint -or $check.Status -eq 'HashMismatch' -or $check.Status -eq 'NotSigned') {
        throw "Signing failed: $($check.Status) $($check.StatusMessage)"
    }
    Write-Host "Signed with $($cert.Subject) ($SigningThumbprint)."
} elseif ($AllowUnsigned) {
    Write-Warning "Signing certificate $SigningThumbprint not found; building UNSIGNED. Installed copies will refuse this as an update."
} else {
    throw "Signing certificate $SigningThumbprint not found in Cert:\CurrentUser\My. Restore it from your .pfx backup (see tools\New-SigningCert.ps1), or pass -AllowUnsigned for a local test build."
}

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

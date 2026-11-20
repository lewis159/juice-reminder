<#
    OPTIONAL. Run on a PC that uses Juice Reminder if you want Windows to show
    "Juice Reminder Release Signing" as the publisher of JuiceReminderSetup.exe
    instead of "Unknown publisher".

    Not needed for updates: the app checks the installer's signature against
    the certificate thumbprint built into it, whether or not this is installed.
    It does not stop SmartScreen's "Windows protected your PC" warning on
    downloaded files either; only a certificate from a public authority (or
    download reputation) does that.

    Adds the PUBLIC certificate assets\juice-signing.cer (no private key) to the
    current user's Trusted Root and Trusted Publishers stores. Windows shows a
    security prompt for the root store; check the thumbprint matches before
    clicking Yes:  4D1E8C6F2D423271B9A0E70A3127F38A353C63B2

    The certificate can only sign code (it can't vouch for websites or issue
    other certificates), but anything signed with its private key will be
    trusted on this PC, so only do this if you trust whoever holds that key.

    Remove it again with -Remove.
#>

[CmdletBinding()]
param(
    [string]$CertPath,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$expected = '4D1E8C6F2D423271B9A0E70A3127F38A353C63B2'

if ($Remove) {
    foreach ($store in 'Root', 'TrustedPublisher') {
        $item = "Cert:\CurrentUser\$store\$expected"
        if (Test-Path $item) { Remove-Item $item; Write-Host "Removed from CurrentUser\$store." }
    }
    return
}

if (-not $CertPath) { $CertPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\juice-signing.cer' }
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertPath)
if ($cert.Thumbprint -ne $expected) {
    throw "Unexpected certificate in $CertPath (thumbprint $($cert.Thumbprint)); expected $expected. Not installing."
}

Import-Certificate -FilePath $CertPath -CertStoreLocation Cert:\CurrentUser\TrustedPublisher | Out-Null
Import-Certificate -FilePath $CertPath -CertStoreLocation Cert:\CurrentUser\Root | Out-Null
Write-Host "Installed $($cert.Subject) ($expected) for the current user."

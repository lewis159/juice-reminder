<#
    Creates the self-signed code-signing certificate used to sign
    JuiceReminderSetup.exe, in the current user's certificate store
    (Cert:\CurrentUser\My). Run once, on the release machine.

    Installed copies of Juice Reminder (1.4.0+) only install updates signed by a
    certificate whose thumbprint is listed in $TrustedSignerThumbprints in
    JuiceReminder.ps1. So after creating it:

      1. Put the printed thumbprint in $TrustedSignerThumbprints
         (JuiceReminder.ps1) and $SigningThumbprint (Build-Installer.ps1).
      2. BACK UP THE PRIVATE KEY (see -Backup below) somewhere off this PC.
         If it is lost, installed copies can't be updated any more and everyone
         has to install the next version by hand.

    Back up an existing certificate to a password-protected .pfx file (you are
    asked for the password):

      powershell -File tools\New-SigningCert.ps1 -Backup -Thumbprint <thumbprint> -PfxPath E:\juice-signing.pfx

    Restore it on another PC with:  Import-PfxCertificate -FilePath E:\juice-signing.pfx -CertStoreLocation Cert:\CurrentUser\My -Password (Read-Host -AsSecureString)
#>

[CmdletBinding(DefaultParameterSetName = 'Create')]
param(
    [Parameter(ParameterSetName = 'Create')]
    [string]$Subject = 'CN=Juice Reminder Release Signing',

    [Parameter(ParameterSetName = 'Create')]
    [int]$Years = 10,

    [Parameter(ParameterSetName = 'Backup', Mandatory)]
    [switch]$Backup,

    [Parameter(ParameterSetName = 'Backup', Mandatory)]
    [string]$Thumbprint,

    [Parameter(ParameterSetName = 'Backup', Mandatory)]
    [string]$PfxPath
)

$ErrorActionPreference = 'Stop'

if ($Backup) {
    $cert = Get-Item "Cert:\CurrentUser\My\$Thumbprint"
    $password = Read-Host -AsSecureString "Password for $PfxPath"
    Export-PfxCertificate -Cert $cert -FilePath $PfxPath -Password $password | Out-Null
    Write-Host "Backed up $($cert.Subject) to $PfxPath. Keep it, and the password, somewhere safe."
    return
}

$existing = @(Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Where-Object { $_.Subject -eq $Subject })
if ($existing.Count -gt 0) {
    Write-Warning "A certificate with subject '$Subject' already exists: $($existing.Thumbprint -join ', '). Not creating another."
    return
}

$cert = New-SelfSignedCertificate `
    -Type CodeSigningCert `
    -Subject $Subject `
    -CertStoreLocation Cert:\CurrentUser\My `
    -KeyAlgorithm RSA -KeyLength 3072 `
    -HashAlgorithm SHA256 `
    -KeyExportPolicy Exportable `
    -NotAfter (Get-Date).AddYears($Years)

Write-Host "Created $($cert.Subject), valid until $($cert.NotAfter.ToString('yyyy-MM-dd'))."
Write-Host "Thumbprint: $($cert.Thumbprint)"
Write-Host ""
Write-Host "Next: put the thumbprint in JuiceReminder.ps1 and Build-Installer.ps1, then back up the key:"
Write-Host "  powershell -File tools\New-SigningCert.ps1 -Backup -Thumbprint $($cert.Thumbprint) -PfxPath <usb or vault path>\juice-signing.pfx"

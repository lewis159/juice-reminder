<#
    JuiceReminder - "have a drink of your juice" popup, every 30 min, 1 hour or 2 hours.

    Usage:
      powershell -ExecutionPolicy Bypass -File JuiceReminder.ps1             (tray app)
      powershell -ExecutionPolicy Bypass -File JuiceReminder.ps1 -TestNow    (one popup, then exit)
      powershell -ExecutionPolicy Bypass -File JuiceReminder.ps1 -Settings   (settings window, then exit)

    Settings: %AppData%\JuiceReminder\settings.json (kept across upgrades).
    Log:      %LocalAppData%\JuiceReminder\logs\juice-reminder.log

    Dot-sourcing this file (. .\JuiceReminder.ps1) only loads the functions, for testing.
#>

[CmdletBinding()]
param(
    # Show one popup straight away and exit (for previewing the design and sound).
    [switch]$TestNow,

    # Open the settings window and exit. A running reminder picks up the change.
    [switch]$Settings,

    # Settings file. Default: %AppData%\JuiceReminder\settings.json
    [string]$SettingsPath,

    # Folder for juice-reminder.log. Rolls over at 1 MB, keeping one old file.
    # Default: %LocalAppData%\JuiceReminder\logs
    [string]$LogDir,

    # For testing: show the first reminder after this many seconds instead of
    # waiting a full interval.
    [int]$StartDelaySeconds = 0,

    # Seconds after start before the first update check (keeps login quick).
    [int]$UpdateCheckDelaySeconds = 120
)

# Read by Build-Installer.ps1 to stamp the installer version.
$AppVersion = '1.4.1'

# Updates are only installed if the installer is Authenticode-signed by one of
# these certificates (SHA-1 thumbprints). The key lives on the release machine;
# see tools\New-SigningCert.ps1. To move to a new certificate, ship a release
# signed with the old one that lists both, then sign with the new one.
$TrustedSignerThumbprints = @(
    '4D1E8C6F2D423271B9A0E70A3127F38A353C63B2'   # CN=Juice Reminder Release Signing (self-signed, 2026-2036)
)

# Where the app looks for updates. Build-Installer.ps1 writes latest.json and it
# is uploaded with each GitHub release; this URL always serves the newest one.
# Can be overridden with UpdateUrl in the settings file.
$DefaultUpdateUrl = 'https://github.com/lewis159/juice-reminder/releases/latest/download/latest.json'
$UpdateModes      = @('Auto', 'Notify', 'Off')
$UpdateDir        = Join-Path $env:TEMP 'JuiceReminderUpdate'

if (-not $SettingsPath) { $SettingsPath = Join-Path $env:APPDATA 'JuiceReminder\settings.json' }
if (-not $LogDir)       { $LogDir       = Join-Path $env:LOCALAPPDATA 'JuiceReminder\logs' }

# Reminder schedule handed from the old version to the new one during an update.
$StatePath = Join-Path (Split-Path -Parent $LogDir) 'update-state.json'

# The only reminder frequencies offered. Anything else in the settings file is ignored.
$IntervalChoices = @(30, 60, 120)
$SnoozeChoices   = @(5, 10, 15, 30)
$DefaultSound    = Join-Path $env:WINDIR 'Media\Windows Notify System Generic.wav'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName PresentationCore   # System.Windows.Media.MediaPlayer (wav, mp3, wma)
[System.Windows.Forms.Application]::EnableVisualStyles()

$CreamColor = [System.Drawing.Color]::FromArgb(255, 250, 244)
$script:player = $null

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )

    # Logging must never take the reminder down, so every failure is swallowed.
    try {
        if (-not (Test-Path $LogDir)) {
            New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        }
        $path = Join-Path $LogDir 'juice-reminder.log'
        if ((Test-Path $path) -and (Get-Item $path).Length -ge 1MB) {
            Move-Item -Path $path -Destination "$path.1" -Force
        }
        $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
        Add-Content -Path $path -Value $line -Encoding UTF8
    }
    catch { }
}

function Format-Minutes {
    param([int]$Minutes)

    if ($Minutes -ge 60 -and $Minutes % 60 -eq 0) {
        $hours = $Minutes / 60
        if ($hours -eq 1) { return '1 hour' }
        return "$hours hours"
    }
    if ($Minutes -eq 1) { return '1 minute' }
    return "$Minutes minutes"
}

# ---------------------------------------------------------------- settings ---

function New-DefaultSettings {
    [pscustomobject]@{
        IntervalMinutes = 60
        SnoozeMinutes   = 10
        SoundEnabled    = $true
        SoundPath       = $DefaultSound
        SoundVolume     = 80
        SoundRepeat     = $false
        UpdateMode      = 'Auto'
        UpdateUrl       = $DefaultUpdateUrl
    }
}

function Test-UpdateUrlAllowed {
    <# Updates only over HTTPS. Plain http is allowed for localhost, for testing. #>
    param([string]$Url)

    $u = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u)) { return $false }
    if ($u.Scheme -eq 'https') { return $true }
    return ($u.Scheme -eq 'http' -and $u.IsLoopback)
}

function ConvertTo-IntOrNull {
    param($Value)

    $n = 0
    if ($null -ne $Value -and [int]::TryParse([string]$Value, [ref]$n)) { return $n }
    return $null
}

function Read-Settings {
    <#
        Returns the settings, falling back to the default for anything missing or
        invalid (and logging what was ignored). Never throws.
    #>
    $s = New-DefaultSettings
    if (-not (Test-Path -LiteralPath $SettingsPath)) { return $s }

    try {
        $raw = Get-Content -LiteralPath $SettingsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Log "Could not read settings file '$SettingsPath': $($_.Exception.Message) Using defaults." 'WARN'
        return $s
    }
    if ($null -eq $raw) { return $s }

    $n = ConvertTo-IntOrNull $raw.IntervalMinutes
    if ($null -ne $n -and $IntervalChoices -contains $n) {
        $s.IntervalMinutes = $n
    } elseif ($null -ne $raw.IntervalMinutes) {
        Write-Log "Ignoring IntervalMinutes '$($raw.IntervalMinutes)': must be one of $($IntervalChoices -join ', ')." 'WARN'
    }

    $n = ConvertTo-IntOrNull $raw.SnoozeMinutes
    if ($null -ne $n -and $n -ge 1 -and $n -le 120) {
        $s.SnoozeMinutes = $n
    } elseif ($null -ne $raw.SnoozeMinutes) {
        Write-Log "Ignoring SnoozeMinutes '$($raw.SnoozeMinutes)': must be 1 to 120." 'WARN'
    }

    if ($raw.SoundEnabled -is [bool]) { $s.SoundEnabled = $raw.SoundEnabled }
    if ($raw.SoundRepeat  -is [bool]) { $s.SoundRepeat  = $raw.SoundRepeat }
    if ($raw.SoundPath -is [string] -and $raw.SoundPath.Trim()) {
        $s.SoundPath = [Environment]::ExpandEnvironmentVariables($raw.SoundPath.Trim())
    }

    $n = ConvertTo-IntOrNull $raw.SoundVolume
    if ($null -ne $n) { $s.SoundVolume = [math]::Max(0, [math]::Min(100, $n)) }

    if ($null -ne $raw.UpdateMode) {
        $mode = $UpdateModes | Where-Object { $_ -eq [string]$raw.UpdateMode } | Select-Object -First 1
        if ($mode) { $s.UpdateMode = $mode }
        else { Write-Log "Ignoring UpdateMode '$($raw.UpdateMode)': must be one of $($UpdateModes -join ', ')." 'WARN' }
    }
    if ($null -ne $raw.UpdateUrl) {
        if (Test-UpdateUrlAllowed ([string]$raw.UpdateUrl)) { $s.UpdateUrl = [string]$raw.UpdateUrl }
        else { Write-Log "Ignoring UpdateUrl '$($raw.UpdateUrl)': must be an https:// address." 'WARN' }
    }

    return $s
}

function Write-Settings {
    param($Settings)

    $dir = Split-Path -Parent $SettingsPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $Settings | ConvertTo-Json | Set-Content -LiteralPath $SettingsPath -Encoding UTF8
}

function Get-SettingsStamp {
    try {
        if (Test-Path -LiteralPath $SettingsPath) {
            return (Get-Item -LiteralPath $SettingsPath).LastWriteTimeUtc.Ticks
        }
    }
    catch { }
    return 0
}

function Get-SettingsSummary {
    param($Settings)

    $sound = 'sound off'
    if ($Settings.SoundEnabled) {
        $sound = "sound '$(Split-Path -Leaf $Settings.SoundPath)' at $($Settings.SoundVolume)%"
        if ($Settings.SoundRepeat) { $sound += ', repeating' }
    }
    return "Every $($Settings.IntervalMinutes) min, snooze $($Settings.SnoozeMinutes) min, $sound, updates $($Settings.UpdateMode)"
}

# ----------------------------------------------------------------- updates ---

function Test-UpdateManifest {
    <#
        Checks the text of latest.json against the running version. Returns
        @{ Ok; Newer; Reason; Version; Url; Sha256; Notes }. Never throws.
        Ok = the manifest is usable; Newer = it offers a later version.
    #>
    param([string]$Json, [string]$CurrentVersion)

    $r = @{ Ok = $false; Newer = $false; Reason = ''; Version = $null; Url = $null; Sha256 = $null; Notes = '' }
    try { $m = $Json | ConvertFrom-Json -ErrorAction Stop }
    catch { $r.Reason = "not valid JSON ($($_.Exception.Message))"; return $r }
    if ($null -eq $m) { $r.Reason = 'empty'; return $r }

    $v = $null
    if (-not [version]::TryParse([string]$m.version, [ref]$v)) { $r.Reason = "bad version '$($m.version)'"; return $r }
    if (-not (Test-UpdateUrlAllowed ([string]$m.url))) { $r.Reason = "download URL '$($m.url)' is not https"; return $r }
    if ([string]$m.sha256 -notmatch '^[0-9A-Fa-f]{64}$') { $r.Reason = 'missing or bad sha256'; return $r }

    $r.Ok      = $true
    $r.Version = $v
    $r.Url     = [string]$m.url
    $r.Sha256  = ([string]$m.sha256).ToUpperInvariant()
    if ($m.notes) { $r.Notes = [string]$m.notes }
    $r.Newer   = $v -gt [version]$CurrentVersion
    return $r
}

function Test-InstallerSignature {
    <#
        Returns $null if the file is signed by a trusted certificate (see
        $TrustedSignerThumbprints) and unchanged since signing, otherwise the
        reason it isn't. Never throws.
    #>
    param([string]$Path)

    try { $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop }
    catch { return "could not read its signature ($($_.Exception.Message))" }

    $cert = $sig.SignerCertificate
    if ($sig.Status -eq 'NotSigned' -or -not $cert) { return 'it is not signed' }
    if ($sig.Status -eq 'HashMismatch') { return 'it was changed after it was signed' }
    if ($TrustedSignerThumbprints -notcontains $cert.Thumbprint) {
        return "it is signed by an unknown certificate ($($cert.Subject), $($cert.Thumbprint))"
    }
    if ($sig.Status -eq 'Valid') { return $null }

    # Our certificate is self-signed, so Windows reports an untrusted root
    # (UnknownError) unless it was added to this PC's trusted roots. The file's
    # digest has still been checked: a changed file gives HashMismatch instead.
    if ($sig.Status -eq 'UnknownError' -and $cert.Subject -eq $cert.Issuer) { return $null }

    return "its signature is not valid ($($sig.Status): $($sig.StatusMessage))"
}

function Test-UpdateFile {
    <# Checksum and signature together. Returns $null if both pass, else the reason. #>
    param([string]$Path, [string]$Sha256)

    if (-not (Test-InstallerHash $Path $Sha256)) { return 'it does not match its SHA-256 checksum' }
    return Test-InstallerSignature $Path
}

function Test-InstallerHash {
    param([string]$Path, [string]$Sha256)

    try {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash -eq $Sha256.ToUpperInvariant()
    }
    catch { return $false }
}

# Network work runs in a background runspace so the tray never freezes. Only one
# job at a time; Invoke-Tick collects the result.
$BackgroundCode = @{
    Fetch = {
        param($Url)
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $wc = New-Object Net.WebClient
        $wc.Headers['User-Agent'] = 'JuiceReminder-Updater'
        $wc.Encoding = [Text.Encoding]::UTF8
        try { $wc.DownloadString($Url) } finally { $wc.Dispose() }
    }
    Download = {
        param($Url, $Dest)
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $dir = Split-Path -Parent $Dest
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $wc = New-Object Net.WebClient
        $wc.Headers['User-Agent'] = 'JuiceReminder-Updater'
        try { $wc.DownloadFile($Url, $Dest) } finally { $wc.Dispose() }
        $Dest
    }
}

function Start-BackgroundJob {
    param([string]$Kind, [object[]]$Arguments)

    $ps = [powershell]::Create()
    [void]$ps.AddScript($BackgroundCode[$Kind].ToString())
    foreach ($a in $Arguments) { [void]$ps.AddArgument($a) }
    $script:job = @{ Kind = $Kind; PS = $ps; Handle = $ps.BeginInvoke(); Started = Get-Date }
}

function Receive-BackgroundJob {
    <#
        If the running job has finished, returns @{ Kind; Output; Error } and
        clears it; otherwise $null. A job running over 5 minutes is abandoned.
    #>
    $j = $script:job
    if (-not $j) { return $null }

    $res = @{ Kind = $j.Kind; Output = $null; Error = $null }
    if ($j.Handle.IsCompleted) {
        try {
            $out = $j.PS.EndInvoke($j.Handle)
            if ($j.PS.Streams.Error.Count -gt 0) { $res.Error = $j.PS.Streams.Error[0].Exception.Message }
            elseif ($out.Count -gt 0) { $res.Output = $out[$out.Count - 1] }
        }
        catch {
            $e = $_.Exception
            while ($e.InnerException) { $e = $e.InnerException }
            $res.Error = $e.Message
        }
    } elseif (((Get-Date) - $j.Started).TotalMinutes -ge 5) {
        try { $j.PS.Stop() } catch { }
        $res.Error = 'timed out after 5 minutes'
    } else {
        return $null
    }

    try { $j.PS.Dispose() } catch { }
    $script:job = $null
    return $res
}

# ------------------------------------------------------------------- sound ---

function Stop-ReminderSound {
    if ($script:player) {
        try { $script:player.Stop(); $script:player.Close() } catch { }
        $script:player = $null
    }
}

function Start-ReminderSound {
    param($Settings)

    Stop-ReminderSound
    if (-not $Settings.SoundEnabled) { return }

    $path = $Settings.SoundPath
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Log "Sound file not found: '$path'. Playing the default chime instead." 'WARN'
        [System.Media.SystemSounds]::Asterisk.Play()
        return
    }

    try {
        $p = New-Object System.Windows.Media.MediaPlayer
        $p.Open([Uri]$path)
        $p.Volume = $Settings.SoundVolume / 100.0
        if ($Settings.SoundRepeat) {
            $p.Add_MediaEnded({
                param($src, $e)
                $src.Position = [TimeSpan]::Zero
                $src.Play()
            })
        }
        $p.Play()
        $script:player = $p
    }
    catch {
        Write-Log "Could not play '$path': $($_.Exception.Message) Playing the default chime instead." 'WARN'
        [System.Media.SystemSounds]::Asterisk.Play()
    }
}

# ------------------------------------------------------------------ window ---

function Get-AppIcon {
    param([System.Drawing.Size]$Size = [System.Drawing.Size]::Empty)

    foreach ($p in @((Join-Path $PSScriptRoot 'juice.ico'), (Join-Path $PSScriptRoot 'assets\juice.ico'))) {
        if (Test-Path -LiteralPath $p) {
            try {
                if ($Size.IsEmpty) { return New-Object System.Drawing.Icon($p) }
                return New-Object System.Drawing.Icon($p, $Size)
            }
            catch { }
        }
    }
    return [System.Drawing.SystemIcons]::Information
}

function New-JuiceReminderForm {
    param($Settings)

    $form                  = New-Object System.Windows.Forms.Form
    $form.Text             = 'Juice time'
    $form.ClientSize       = New-Object System.Drawing.Size(440, 250)
    $form.FormBorderStyle  = 'FixedDialog'
    $form.StartPosition    = 'CenterScreen'
    $form.TopMost          = $true
    $form.ControlBox       = $false
    $form.ShowInTaskbar    = $true
    $form.BackColor        = $CreamColor

    # Hand-drawn glass of juice, so the script stays plain ASCII on disk.
    $glass = New-Object System.Windows.Forms.Panel
    $glass.SetBounds(24, 30, 96, 130)
    $glass.BackColor = [System.Drawing.Color]::Transparent
    $glass.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = 'AntiAlias'

        $juice = New-Object System.Drawing.Drawing2D.GraphicsPath
        $juice.AddPolygon(@(
            (New-Object System.Drawing.Point(24, 40)),
            (New-Object System.Drawing.Point(72, 40)),
            (New-Object System.Drawing.Point(64, 112)),
            (New-Object System.Drawing.Point(32, 112))
        ))
        $fill = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            (New-Object System.Drawing.Point(0, 40)),
            (New-Object System.Drawing.Point(0, 112)),
            [System.Drawing.Color]::FromArgb(255, 176, 59),
            [System.Drawing.Color]::FromArgb(233, 112, 32))
        $g.FillPath($fill, $juice)
        $fill.Dispose(); $juice.Dispose()

        $outline = New-Object System.Drawing.Pen -ArgumentList ([System.Drawing.Color]::FromArgb(120, 90, 60)), 2
        $g.DrawPolygon($outline, @(
            (New-Object System.Drawing.Point(20, 20)),
            (New-Object System.Drawing.Point(76, 20)),
            (New-Object System.Drawing.Point(64, 114)),
            (New-Object System.Drawing.Point(32, 114))
        ))

        # Straw.
        $straw = New-Object System.Drawing.Pen -ArgumentList ([System.Drawing.Color]::FromArgb(228, 90, 90)), 6
        $straw.StartCap = 'Round'; $straw.EndCap = 'Round'
        $g.DrawLine($straw, 58, 4, 44, 70)

        $outline.Dispose(); $straw.Dispose()
    })
    $form.Controls.Add($glass)

    $title           = New-Object System.Windows.Forms.Label
    $title.Text      = 'Time for a drink of your juice'
    $title.Font      = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = [System.Drawing.Color]::FromArgb(60, 45, 30)
    $title.SetBounds(140, 46, 280, 60)
    $form.Controls.Add($title)

    $sub             = New-Object System.Windows.Forms.Label
    $sub.Text        = "Next reminder in $(Format-Minutes $Settings.IntervalMinutes)."
    $sub.Font        = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $sub.ForeColor   = [System.Drawing.Color]::FromArgb(130, 115, 100)
    $sub.SetBounds(142, 108, 280, 22)
    $form.Controls.Add($sub)

    $ok               = New-Object System.Windows.Forms.Button
    $ok.Text          = 'OK'
    $ok.Font          = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $ok.SetBounds(280, 180, 130, 40)
    $ok.DialogResult  = [System.Windows.Forms.DialogResult]::OK
    $ok.BackColor     = [System.Drawing.Color]::FromArgb(255, 176, 59)
    $ok.ForeColor     = [System.Drawing.Color]::FromArgb(50, 35, 20)
    $ok.FlatStyle     = 'Flat'
    $ok.FlatAppearance.BorderSize = 0
    $form.Controls.Add($ok)

    $snooze              = New-Object System.Windows.Forms.Button
    $snooze.Text         = "Snooze $($Settings.SnoozeMinutes) min"
    $snooze.Font         = New-Object System.Drawing.Font('Segoe UI', 10)
    $snooze.SetBounds(140, 180, 130, 40)
    $snooze.DialogResult = [System.Windows.Forms.DialogResult]::Retry
    $snooze.FlatStyle    = 'Flat'
    $snooze.BackColor    = [System.Drawing.Color]::FromArgb(240, 233, 224)
    $snooze.ForeColor    = [System.Drawing.Color]::FromArgb(90, 75, 60)
    $snooze.FlatAppearance.BorderSize = 0
    $form.Controls.Add($snooze)

    $form.AcceptButton = $ok
    return $form
}

function Show-JuiceReminder {
    # $OnShown is for tests: it runs with the form once it is on screen.
    param($Settings, [scriptblock]$OnShown)

    $form = New-JuiceReminderForm $Settings

    # Come to the front even if something else is fullscreen.
    $form.Add_Shown({
        $form.Activate()
        $form.BringToFront()
        Start-ReminderSound $Settings
        if ($OnShown) { & $OnShown $form }
    })
    $form.Add_FormClosed({ Stop-ReminderSound })

    $result = $form.ShowDialog()
    $form.Dispose()
    return $result
}

function Show-SettingsDialog {
    <#
        Shows the settings window. Returns the new settings if the user clicked
        Save, otherwise $null.

        Built and shown in one function on purpose: the event handlers below find
        the controls through PowerShell's dynamic scoping, which only works while
        this function is still running (inside ShowDialog). Don't split it up or
        use GetNewClosure(); closures can't see this script's functions.
        $OnShown is for tests: it runs with the form once it is on screen.
    #>
    param($Current, [scriptblock]$OnShown)

    $state  = @{ Previewing = $false }
    $sounds = New-Object System.Collections.ArrayList   # full paths, same order as the sound list
    $media  = Join-Path $env:WINDIR 'Media'

    foreach ($f in @(Get-ChildItem -LiteralPath $media -Filter '*.wav' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        [void]$sounds.Add($f.FullName)
    }
    if ($Current.SoundPath -and -not ($sounds -contains $Current.SoundPath)) {
        [void]$sounds.Insert(0, $Current.SoundPath)
    }
    $soundLabel = {
        param([string]$Path)
        if ((Split-Path -Parent $Path) -eq $media) { return [IO.Path]::GetFileNameWithoutExtension($Path) }
        return "$(Split-Path -Leaf $Path) (your file)"
    }

    $snoozeValues = @($SnoozeChoices)
    if ($snoozeValues -notcontains $Current.SnoozeMinutes) {
        $snoozeValues = @($snoozeValues + $Current.SnoozeMinutes | Sort-Object)
    }

    $form                 = New-Object System.Windows.Forms.Form
    $form.Text            = 'Juice Reminder settings'
    $form.ClientSize      = New-Object System.Drawing.Size(460, 398)
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox     = $false
    $form.MinimizeBox     = $false
    $form.StartPosition   = 'CenterScreen'
    $form.TopMost         = $true
    $form.BackColor       = $CreamColor
    $form.Font            = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $form.Icon            = Get-AppIcon

    $addLabel = {
        param([string]$Text, [int]$Y)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $Text
        $l.SetBounds(24, $Y, 140, 24)
        $l.TextAlign = 'MiddleLeft'
        $form.Controls.Add($l)
    }

    & $addLabel 'Remind me every' 24
    $intervalBox = New-Object System.Windows.Forms.ComboBox
    $intervalBox.DropDownStyle = 'DropDownList'
    $intervalBox.SetBounds(170, 24, 180, 28)
    foreach ($m in $IntervalChoices) { [void]$intervalBox.Items.Add((Format-Minutes $m)) }
    $intervalBox.SelectedIndex = [math]::Max(0, [array]::IndexOf($IntervalChoices, [int]$Current.IntervalMinutes))
    $form.Controls.Add($intervalBox)

    & $addLabel 'Snooze for' 64
    $snoozeBox = New-Object System.Windows.Forms.ComboBox
    $snoozeBox.DropDownStyle = 'DropDownList'
    $snoozeBox.SetBounds(170, 64, 180, 28)
    foreach ($m in $snoozeValues) { [void]$snoozeBox.Items.Add((Format-Minutes $m)) }
    $snoozeBox.SelectedIndex = [math]::Max(0, [array]::IndexOf($snoozeValues, [int]$Current.SnoozeMinutes))
    $form.Controls.Add($snoozeBox)

    $soundChk = New-Object System.Windows.Forms.CheckBox
    $soundChk.Text = 'Play a sound with the reminder'
    $soundChk.SetBounds(24, 108, 300, 24)
    $soundChk.Checked = [bool]$Current.SoundEnabled
    $form.Controls.Add($soundChk)

    & $addLabel 'Sound' 142
    $soundBox = New-Object System.Windows.Forms.ComboBox
    $soundBox.DropDownStyle = 'DropDownList'
    $soundBox.SetBounds(170, 142, 180, 28)
    $soundBox.MaxDropDownItems = 15
    foreach ($p in $sounds) { [void]$soundBox.Items.Add((& $soundLabel $p)) }
    $soundBox.SelectedIndex = [math]::Max(0, $sounds.IndexOf($Current.SoundPath))
    $form.Controls.Add($soundBox)

    $browse = New-Object System.Windows.Forms.Button
    $browse.Text = 'Browse...'
    $browse.SetBounds(358, 141, 80, 28)
    $form.Controls.Add($browse)

    & $addLabel 'Volume' 182
    $vol = New-Object System.Windows.Forms.TrackBar
    $vol.SetBounds(164, 178, 220, 45)
    $vol.Minimum = 0; $vol.Maximum = 100
    $vol.TickFrequency = 10; $vol.SmallChange = 5; $vol.LargeChange = 10
    $vol.Value = [int]$Current.SoundVolume
    $vol.BackColor = $CreamColor
    $form.Controls.Add($vol)

    $volLabel = New-Object System.Windows.Forms.Label
    $volLabel.SetBounds(390, 182, 50, 24)
    $volLabel.TextAlign = 'MiddleLeft'
    $volLabel.Text = "$($vol.Value)%"
    $form.Controls.Add($volLabel)

    $repeat = New-Object System.Windows.Forms.CheckBox
    $repeat.Text = 'Keep repeating until I click OK or Snooze'
    $repeat.SetBounds(170, 226, 280, 24)
    $repeat.Checked = [bool]$Current.SoundRepeat
    $form.Controls.Add($repeat)

    $preview = New-Object System.Windows.Forms.Button
    $preview.Text = 'Preview'
    $preview.SetBounds(170, 258, 100, 30)
    $form.Controls.Add($preview)

    & $addLabel 'Updates' 306
    $updateNames = @('Install automatically', 'Ask me first', "Don't check")   # same order as $UpdateModes
    $updateBox = New-Object System.Windows.Forms.ComboBox
    $updateBox.DropDownStyle = 'DropDownList'
    $updateBox.SetBounds(170, 306, 180, 28)
    foreach ($n in $updateNames) { [void]$updateBox.Items.Add($n) }
    $updateBox.SelectedIndex = [math]::Max(0, [array]::IndexOf($UpdateModes, [string]$Current.UpdateMode))
    $form.Controls.Add($updateBox)

    $save = New-Object System.Windows.Forms.Button
    $save.Text = 'Save'
    $save.SetBounds(254, 352, 90, 32)
    $save.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $save.BackColor = [System.Drawing.Color]::FromArgb(255, 176, 59)
    $save.FlatStyle = 'Flat'
    $save.FlatAppearance.BorderSize = 0
    $form.Controls.Add($save)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.SetBounds(350, 352, 90, 32)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancel)

    $form.AcceptButton = $save
    $form.CancelButton = $cancel

    $collect = {
        $path = $Current.SoundPath
        if ($soundBox.SelectedIndex -ge 0) { $path = $sounds[$soundBox.SelectedIndex] }
        [pscustomobject]@{
            IntervalMinutes = $IntervalChoices[$intervalBox.SelectedIndex]
            SnoozeMinutes   = $snoozeValues[$snoozeBox.SelectedIndex]
            SoundEnabled    = $soundChk.Checked
            SoundPath       = $path
            SoundVolume     = $vol.Value
            SoundRepeat     = $repeat.Checked
            UpdateMode      = $UpdateModes[$updateBox.SelectedIndex]
            UpdateUrl       = $Current.UpdateUrl   # not shown; file-only
        }
    }

    $stopPreview = {
        Stop-ReminderSound
        $state.Previewing = $false
        $preview.Text = 'Preview'
    }

    $syncEnabled = {
        foreach ($c in @($soundBox, $browse, $vol, $volLabel, $repeat, $preview)) { $c.Enabled = $soundChk.Checked }
        if (-not $soundChk.Checked) { & $stopPreview }
    }
    & $syncEnabled

    $soundChk.Add_CheckedChanged($syncEnabled)
    $soundBox.Add_SelectedIndexChanged({ if ($state.Previewing) { & $stopPreview } })

    $vol.Add_ValueChanged({
        $volLabel.Text = "$($vol.Value)%"
        if ($script:player) { $script:player.Volume = $vol.Value / 100.0 }
    })

    $browse.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title  = 'Choose a sound'
        $dlg.Filter = 'Sound files (*.wav;*.mp3;*.wma;*.m4a)|*.wav;*.mp3;*.wma;*.m4a|All files (*.*)|*.*'
        if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $i = $sounds.IndexOf($dlg.FileName)
            if ($i -lt 0) {
                [void]$sounds.Insert(0, $dlg.FileName)
                $soundBox.Items.Insert(0, (& $soundLabel $dlg.FileName))
                $i = 0
            }
            $soundBox.SelectedIndex = $i
        }
        $dlg.Dispose()
    })

    $preview.Add_Click({
        if ($state.Previewing) { & $stopPreview; return }
        $trial = & $collect
        $trial.SoundEnabled = $true
        Start-ReminderSound $trial
        if (-not $script:player) { return }   # fell back to the system chime
        $state.Previewing = $true
        $preview.Text = 'Stop'
        if (-not $trial.SoundRepeat) { $script:player.Add_MediaEnded($stopPreview) }
    })

    $form.Add_Shown({
        $form.Activate()
        if ($OnShown) { & $OnShown $form }
    })

    $result = $null
    try {
        if ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $result = & $collect
        }
    }
    finally {
        Stop-ReminderSound
        $form.Dispose()
    }
    return $result
}

# Dot-sourced for testing: stop here, with the functions loaded.
if ($MyInvocation.InvocationName -eq '.') { return }

# --------------------------------------------------------- one-shot modes ---

# Neither mode takes the single-instance lock, so both work while the real
# reminder is running.
if ($TestNow) {
    Write-Log "Test popup opened (v$AppVersion, PID $PID)."
    $answer = Show-JuiceReminder (Read-Settings)
    Write-Log "Test popup closed with $answer."
    return
}

if ($Settings) {
    $new = Show-SettingsDialog (Read-Settings)
    if ($new) {
        Write-Settings $new
        Write-Log "Settings saved from the settings window. $(Get-SettingsSummary $new)."
    }
    return
}

# ---------------------------------------------------------------- tray app ---

function Get-NextDue { $script:anchor.AddMinutes($script:waitMinutes) }

function Update-TrayText {
    if (-not $script:tray) { return }
    if ($script:paused) {
        $text = 'Juice Reminder - paused'
    } else {
        $text = 'Juice Reminder - next at {0:HH:mm}' -f (Get-NextDue)
    }
    $script:tray.Text   = $text
    $script:miNext.Text = $text.Replace('Juice Reminder - ', 'Next reminder: ').Replace('Next reminder: paused', 'Reminders paused')
    $script:miPause.Checked = $script:paused
}

function Set-AppSettings {
    param($New, [string]$Why)

    $script:appSettings = $New
    # A snooze in progress keeps its own wait; otherwise the new interval counts
    # from the last reminder (or start), so a shorter one can fire straight away.
    if (-not $script:snoozed) { $script:waitMinutes = $New.IntervalMinutes }
    Write-Log "$Why. $(Get-SettingsSummary $New)."
    Update-TrayText
}

function Update-SettingsIfChanged {
    $stamp = Get-SettingsStamp
    if ($stamp -eq $script:settingsStamp) { return }
    $script:settingsStamp = $stamp
    Set-AppSettings (Read-Settings) 'Settings file changed'
}

function Invoke-Reminder {
    param([string]$Why)

    $script:busy = $true
    try {
        $due  = Get-NextDue
        $late = ((Get-Date) - $due).TotalMinutes
        if ($Why -eq 'timer' -and $late -ge 2) {
            Write-Log ("Reminder shown {0:N0} min late (was due {1:HH:mm}; PC was probably asleep or locked)." -f $late, $due)
        } else {
            Write-Log "Reminder shown ($Why)."
        }

        $shownAt = Get-Date
        $answer  = Show-JuiceReminder $script:appSettings
        $seconds = [int]((Get-Date) - $shownAt).TotalSeconds

        $script:anchor = Get-Date
        if ($answer -eq [System.Windows.Forms.DialogResult]::Retry) {
            $script:snoozed     = $true
            $script:waitMinutes = $script:appSettings.SnoozeMinutes
            Write-Log "Snoozed after $seconds s. Next reminder in $($script:waitMinutes) min."
        } else {
            $script:snoozed     = $false
            $script:waitMinutes = $script:appSettings.IntervalMinutes
            $how = if ($answer -eq [System.Windows.Forms.DialogResult]::OK) { 'OK clicked' } else { "Closed ($answer)" }
            Write-Log "$how after $seconds s. Next reminder in $($script:waitMinutes) min."
        }
    }
    catch {
        # Never retry in a tight loop: wait a normal interval and carry on.
        $script:anchor      = Get-Date
        $script:snoozed     = $false
        $script:waitMinutes = $script:appSettings.IntervalMinutes
        Write-Log "Reminder failed: $($_.Exception.Message) Next try in $($script:waitMinutes) min." 'ERROR'
    }
    finally {
        $script:busy = $false
        Update-TrayText
    }
}

function Show-TrayMessage {
    param([string]$Text, [string]$Icon = 'Info')

    if (-not $script:tray -or -not $script:tray.Visible) { return }
    $script:tray.BalloonTipTitle = 'Juice Reminder'
    $script:tray.BalloonTipText  = $Text
    $script:tray.BalloonTipIcon  = $Icon
    $script:tray.ShowBalloonTip(10000)
}

function Update-UpdateMenu {
    if (-not $script:miInstall) { return }
    $u = $script:update
    $script:miInstall.Available = [bool]$u
    if ($u) { $script:miInstall.Text = "Install update $($u.Version) now" }
}

function Start-UpdateCheck {
    param([switch]$Manual)

    if ($script:job -or $script:installing) { return }
    $script:manualCheck     = [bool]$Manual
    $script:nextUpdateCheck = (Get-Date).AddHours(24)
    Start-BackgroundJob 'Fetch' @($script:appSettings.UpdateUrl)
}

function Start-UpdateDownload {
    if ($script:job -or -not $script:update) { return }
    $dest = Join-Path $UpdateDir ('JuiceReminderSetup-{0}.exe' -f $script:update.Version)
    Write-Log "Downloading update v$($script:update.Version) from $($script:update.Url)."
    Start-BackgroundJob 'Download' @($script:update.Url, $dest)
}

function Complete-UpdateCheck {
    param($Result)

    $manual = $script:manualCheck
    $script:manualCheck = $false

    if ($Result.Error) {
        $script:nextUpdateCheck = (Get-Date).AddHours(6)
        Write-Log "Update check failed: $($Result.Error)" 'WARN'
        if ($manual) { Show-TrayMessage "Couldn't check for updates: $($Result.Error)" 'Warning' }
        return
    }

    $m = Test-UpdateManifest ([string]$Result.Output) $AppVersion
    if (-not $m.Ok) {
        $script:nextUpdateCheck = (Get-Date).AddHours(6)
        Write-Log "Update information rejected: $($m.Reason)." 'WARN'
        if ($manual) { Show-TrayMessage "Couldn't check for updates: the update information was not valid." 'Warning' }
        return
    }
    if (-not $m.Newer) {
        Write-Log "Checked for updates: up to date (running v$AppVersion, latest v$($m.Version))."
        if ($manual) { Show-TrayMessage "You have the latest version ($AppVersion)." }
        return
    }

    # Same version already downloaded and verified: nothing new to do.
    if ($script:update -and $script:update.Version -eq $m.Version -and $script:update.File) {
        if ($manual) { Show-TrayMessage "Version $($m.Version) is ready to install. Right-click the tray icon and choose Install update." }
        return
    }

    $script:update = $m
    Write-Log "Update v$($m.Version) available (running v$AppVersion)."
    Update-UpdateMenu

    if ($script:appSettings.UpdateMode -eq 'Auto' -or $script:installWhenReady) {
        Start-UpdateDownload
    } else {
        Show-TrayMessage "Version $($m.Version) is available. Right-click the tray icon and choose Install update."
    }
}

function Complete-UpdateDownload {
    param($Result)

    $u = $script:update
    if ($Result.Error) {
        Write-Log "Update download failed: $($Result.Error)" 'WARN'
        if ($script:installWhenReady) { Show-TrayMessage "Couldn't download the update: $($Result.Error)" 'Warning' }
        $script:installWhenReady = $false
        $script:nextUpdateCheck  = (Get-Date).AddHours(6)
        return
    }

    $file = [string]$Result.Output
    $problem = Test-UpdateFile $file $u.Sha256
    if ($problem) {
        Write-Log "Downloaded update v$($u.Version) rejected: $problem. Deleted it; not installing." 'ERROR'
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        if ($script:installWhenReady) { Show-TrayMessage 'The downloaded update was damaged or tampered with, so it was not installed.' 'Error' }
        $script:update           = $null
        $script:installWhenReady = $false
        $script:nextUpdateCheck  = (Get-Date).AddHours(6)
        Update-UpdateMenu
        return
    }

    $u.File = $file
    Write-Log "Update v$($u.Version) downloaded; checksum and signature verified: $file"
    Update-UpdateMenu

    # Auto mode installs straight away. Invoke-Tick never runs while a reminder
    # or the settings window is open, so this can't interrupt either; the
    # reminder schedule carries over to the new version (see Save-UpdateState).
    if ($script:installWhenReady -or $script:appSettings.UpdateMode -eq 'Auto') {
        Install-Update
    }
}

function Save-UpdateState {
    <#
        Saves the reminder schedule just before an update restarts the app, so
        the new version carries on where this one left off.
    #>
    try {
        $dir = Split-Path -Parent $StatePath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [pscustomobject]@{
            FromVersion = $AppVersion
            ToVersion   = [string]$script:update.Version
            SavedAt     = (Get-Date).ToString('o')
            Anchor      = $script:anchor.ToString('o')
            WaitMinutes = $script:waitMinutes
            Snoozed     = $script:snoozed
            Paused      = $script:paused
        } | ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding UTF8
    }
    catch { Write-Log "Could not save the reminder schedule before updating: $($_.Exception.Message)" 'WARN' }
}

function Restore-UpdateState {
    <#
        If this start follows an update (state saved under 15 minutes ago),
        restores the reminder schedule and returns the version updated from.
        Always deletes the state file. Returns $null otherwise.
    #>
    if (-not (Test-Path -LiteralPath $StatePath)) { return $null }
    try {
        $st = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        $saved = [datetime]::Parse($st.SavedAt, $null, [Globalization.DateTimeStyles]::RoundtripKind)
        if (((Get-Date) - $saved).TotalMinutes -gt 15) { return $null }

        $script:anchor      = [datetime]::Parse($st.Anchor, $null, [Globalization.DateTimeStyles]::RoundtripKind)
        $script:waitMinutes = [double]$st.WaitMinutes
        $script:snoozed     = [bool]$st.Snoozed
        $script:paused      = [bool]$st.Paused
        return [string]$st.FromVersion
    }
    catch {
        Write-Log "Could not restore the reminder schedule after updating: $($_.Exception.Message)" 'WARN'
        return $null
    }
    finally {
        Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
    }
}

function Install-Update {
    $u = $script:update
    if (-not $u -or -not $u.File -or $script:installing) { return }

    # Check again right before running it: the file sits in a user-writable folder.
    $problem = Test-UpdateFile $u.File $u.Sha256
    if ($problem) {
        Write-Log "Update file $($u.File) failed its re-check before installing: $problem. Deleted it; not installing." 'ERROR'
        Remove-Item -LiteralPath $u.File -Force -ErrorAction SilentlyContinue
        $script:update = $null
        Update-UpdateMenu
        return
    }

    $setupLog = Join-Path $UpdateDir 'setup.log'
    Write-Log "Installing update v$($u.Version). Setup's own log: $setupLog"
    Save-UpdateState
    try {
        Start-Process -FilePath $u.File -ErrorAction Stop -ArgumentList @(
            '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/RESTARTAPP=1', "/LOG=`"$setupLog`"")
    }
    catch {
        Write-Log "Could not start the update: $($_.Exception.Message)" 'ERROR'
        Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
        return
    }

    # Setup stops this process and starts the new version. Hide the tray icon so
    # it doesn't linger; Invoke-Tick brings it back if setup never gets that far.
    $script:installing     = $true
    $script:installStarted = Get-Date
    $script:installWhenReady = $false
    $script:tray.Visible   = $false
}

function Request-UpdateInstall {
    <# The user asked to install now (tray menu or notification). #>
    if (-not $script:update -or $script:installing) { return }
    $script:installWhenReady = $true
    if ($script:update.File) {
        Install-Update
    } else {
        Show-TrayMessage "Downloading version $($script:update.Version)..."
        Start-UpdateDownload   # if a check is still running, it downloads when that finishes
    }
}

function Invoke-UpdateWork {
    $res = Receive-BackgroundJob
    if ($res) {
        if ($res.Kind -eq 'Fetch') { Complete-UpdateCheck $res } else { Complete-UpdateDownload $res }
    }

    if ($script:installing -and ((Get-Date) - $script:installStarted).TotalMinutes -ge 3) {
        $script:installing   = $false
        $script:tray.Visible = $true
        Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
        Write-Log "Update v$($script:update.Version) did not complete within 3 minutes; still running v$AppVersion. See $(Join-Path $UpdateDir 'setup.log')." 'WARN'
    }

    if ($script:appSettings.UpdateMode -ne 'Off' -and -not $script:job -and -not $script:installing -and
        (Get-Date) -ge $script:nextUpdateCheck) {
        Start-UpdateCheck
    }
}

function Invoke-Tick {
    if ($script:busy) { return }
    try {
        Update-SettingsIfChanged
        # Update trouble must never stop reminders.
        try { Invoke-UpdateWork } catch { Write-Log "Update step failed: $($_.Exception.Message)" 'ERROR' }
        if (-not $script:installing -and -not $script:paused -and (Get-Date) -ge (Get-NextDue)) {
            Invoke-Reminder 'timer'
        }
    }
    catch {
        Write-Log "Timer tick failed: $($_.Exception.Message)" 'ERROR'
    }
}

function Open-SettingsFromTray {
    if ($script:busy) { return }
    $script:busy = $true
    try {
        $new = Show-SettingsDialog $script:appSettings
        if ($new) {
            Write-Settings $new
            $script:settingsStamp = Get-SettingsStamp
            Set-AppSettings $new 'Settings saved'
        }
    }
    catch {
        Write-Log "Settings window failed: $($_.Exception.Message)" 'ERROR'
    }
    finally {
        $script:busy = $false
    }
}

# Only one copy per signed-in user, even if Windows launches it twice. Local\
# (not Global\) so other users on the same PC get their own reminder.
$mutex = New-Object System.Threading.Mutex($false, 'Local\JuiceReminderSingleInstance')
$owned = $false
try { $owned = $mutex.WaitOne(0, $false) }
catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) {
    Write-Log "Another copy is already running; exiting (PID $PID)."
    $mutex.Dispose()
    return
}

$script:tray  = $null
$script:timer = $null
try {
    $script:appSettings = Read-Settings
    if (-not (Test-Path -LiteralPath $SettingsPath)) {
        try {
            Write-Settings $script:appSettings
            Write-Log "Created settings file $SettingsPath with the defaults."
        }
        catch { Write-Log "Could not create settings file: $($_.Exception.Message)" 'WARN' }
    }
    $script:settingsStamp = Get-SettingsStamp
    $script:anchor        = Get-Date
    $script:waitMinutes   = $script:appSettings.IntervalMinutes
    $script:snoozed       = $false
    $script:paused        = $false
    $script:busy          = $false

    $script:job              = $null
    $script:update           = $null    # Test-UpdateManifest result, plus File once downloaded
    $script:installWhenReady = $false
    $script:manualCheck      = $false
    $script:installing       = $false
    $script:nextUpdateCheck  = (Get-Date).AddSeconds($UpdateCheckDelaySeconds)
    # Installers left from earlier updates are no longer needed.
    Get-ChildItem -LiteralPath $UpdateDir -Filter '*.exe' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    if ($StartDelaySeconds -gt 0) {
        $script:waitMinutes = $StartDelaySeconds / 60.0
        $script:snoozed     = $true   # keep the test delay even if settings change
    }

    $updatedFrom = Restore-UpdateState

    Write-Log "Started v$AppVersion (PID $PID). $(Get-SettingsSummary $script:appSettings). Settings: $SettingsPath. Script: $PSCommandPath"
    if ($updatedFrom) {
        $paused = if ($script:paused) { ' Reminders are still paused.' } else { '' }
        Write-Log ("Updated from v$updatedFrom. Reminder schedule kept: next reminder at {0:HH:mm}.$paused" -f (Get-NextDue))
    }

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $script:miNext = $menu.Items.Add('Next reminder:')
    $script:miNext.Enabled = $false
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miNow      = $menu.Items.Add('Remind me now')
    $script:miPause = $menu.Items.Add('Pause reminders')
    $miSettings = $menu.Items.Add('Settings...')
    $miSettings.Font = New-Object System.Drawing.Font($miSettings.Font, [System.Drawing.FontStyle]::Bold)
    $miLog      = $menu.Items.Add('Open log folder')
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $script:miInstall = $menu.Items.Add('Install update')
    $miCheck    = $menu.Items.Add('Check for updates')
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miExit     = $menu.Items.Add('Exit')
    Update-UpdateMenu

    $script:miInstall.Add_Click({ Request-UpdateInstall })
    $miCheck.Add_Click({
        if ($script:job) { Show-TrayMessage 'Already checking for updates.'; return }
        Write-Log 'Update check requested from the tray menu.'
        Start-UpdateCheck -Manual
    })

    $miNow.Add_Click({ if (-not $script:busy) { Invoke-Reminder 'from tray menu' } })
    $miSettings.Add_Click({ Open-SettingsFromTray })
    $miLog.Add_Click({ Start-Process explorer.exe $LogDir })
    $script:miPause.Add_Click({
        if ($script:paused) {
            $script:paused      = $false
            $script:snoozed     = $false
            $script:anchor      = Get-Date
            $script:waitMinutes = $script:appSettings.IntervalMinutes
            Write-Log "Resumed from the tray menu. Next reminder in $($script:waitMinutes) min."
        } else {
            $script:paused = $true
            Write-Log 'Paused from the tray menu.'
        }
        Update-TrayText
    })
    $miExit.Add_Click({
        Write-Log 'Exit chosen from the tray menu.'
        [System.Windows.Forms.Application]::Exit()
    })
    $menu.Add_Opening({ Update-TrayText })

    $script:tray = New-Object System.Windows.Forms.NotifyIcon
    $script:tray.Icon = Get-AppIcon ([System.Windows.Forms.SystemInformation]::SmallIconSize)
    $script:tray.ContextMenuStrip = $menu
    $script:tray.Add_MouseDoubleClick({ Open-SettingsFromTray })
    $script:tray.Add_BalloonTipClicked({
        if (-not $script:update -or $script:installing -or $script:busy) { return }
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "Install Juice Reminder $($script:update.Version) now?`r`n`r`nThe reminder restarts by itself; your settings are kept.",
            'Juice Reminder update', 'YesNo', 'Question')
        if ($answer -eq 'Yes') { Request-UpdateInstall }
    })
    Update-TrayText
    $script:tray.Visible = $true
    if ($updatedFrom -and $updatedFrom -ne $AppVersion) {
        Show-TrayMessage "Juice Reminder updated to version $AppVersion."
    }

    # Check the clock every 15 s rather than sleeping for a whole interval:
    # sleep timers stop while the PC is asleep, the clock does not.
    $script:timer = New-Object System.Windows.Forms.Timer
    $script:timer.Interval = 15000
    $script:timer.Add_Tick({ Invoke-Tick })
    $script:timer.Start()

    [System.Windows.Forms.Application]::Run()
}
catch {
    Write-Log "Crashed: $($_.Exception.Message)" 'ERROR'
    throw
}
finally {
    if ($script:timer) { $script:timer.Stop(); $script:timer.Dispose() }
    if ($script:tray)  { $script:tray.Visible = $false; $script:tray.Dispose() }
    if ($script:job)   { try { $script:job.PS.Stop(); $script:job.PS.Dispose() } catch { } }
    Stop-ReminderSound
    Write-Log 'Stopped.'
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}

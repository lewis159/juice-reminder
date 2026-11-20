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
    [int]$StartDelaySeconds = 0
)

# Read by Build-Installer.ps1 to stamp the installer version.
$AppVersion = '1.2.0'

if (-not $SettingsPath) { $SettingsPath = Join-Path $env:APPDATA 'JuiceReminder\settings.json' }
if (-not $LogDir)       { $LogDir       = Join-Path $env:LOCALAPPDATA 'JuiceReminder\logs' }

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
    }
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
    return "Every $($Settings.IntervalMinutes) min, snooze $($Settings.SnoozeMinutes) min, $sound"
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
    $form.ClientSize      = New-Object System.Drawing.Size(460, 344)
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

    $save = New-Object System.Windows.Forms.Button
    $save.Text = 'Save'
    $save.SetBounds(254, 300, 90, 32)
    $save.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $save.BackColor = [System.Drawing.Color]::FromArgb(255, 176, 59)
    $save.FlatStyle = 'Flat'
    $save.FlatAppearance.BorderSize = 0
    $form.Controls.Add($save)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.SetBounds(350, 300, 90, 32)
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

function Invoke-Tick {
    if ($script:busy) { return }
    try {
        Update-SettingsIfChanged
        if (-not $script:paused -and (Get-Date) -ge (Get-NextDue)) {
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
    if ($StartDelaySeconds -gt 0) {
        $script:waitMinutes = $StartDelaySeconds / 60.0
        $script:snoozed     = $true   # keep the test delay even if settings change
    }

    Write-Log "Started v$AppVersion (PID $PID). $(Get-SettingsSummary $script:appSettings). Settings: $SettingsPath. Script: $PSCommandPath"

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
    $miExit     = $menu.Items.Add('Exit')

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
    Update-TrayText
    $script:tray.Visible = $true

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
    Stop-ReminderSound
    Write-Log 'Stopped.'
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}

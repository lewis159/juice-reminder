<#
    JuiceReminder - hourly "have a drink of your juice" popup.

    Usage:
      powershell -ExecutionPolicy Bypass -File JuiceReminder.ps1
      powershell -ExecutionPolicy Bypass -File JuiceReminder.ps1 -TestNow
#>

[CmdletBinding()]
param(
    # Minutes between reminders.
    [int]$IntervalMinutes = 60,

    # Minutes to wait when the user hits Snooze.
    [int]$SnoozeMinutes = 10,

    # Show one popup straight away and exit (for previewing the design).
    [switch]$TestNow
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Only ever one copy running, even if Windows launches it twice.
$mutex = New-Object System.Threading.Mutex($false, 'Global\JuiceReminderSingleInstance')
if (-not $mutex.WaitOne(0, $false)) { return }

function Show-JuiceReminder {
    $form                  = New-Object System.Windows.Forms.Form
    $form.Text             = 'Juice time'
    $form.ClientSize       = New-Object System.Drawing.Size(440, 250)
    $form.FormBorderStyle  = 'FixedDialog'
    $form.StartPosition    = 'CenterScreen'
    $form.TopMost          = $true
    $form.ControlBox       = $false
    $form.BackColor        = [System.Drawing.Color]::FromArgb(255, 250, 244)

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
    $sub.Text        = "Next reminder in $IntervalMinutes minutes."
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
    $snooze.Text         = "Snooze $SnoozeMinutes min"
    $snooze.Font         = New-Object System.Drawing.Font('Segoe UI', 10)
    $snooze.SetBounds(140, 180, 130, 40)
    $snooze.DialogResult = [System.Windows.Forms.DialogResult]::Retry
    $snooze.FlatStyle    = 'Flat'
    $snooze.BackColor    = [System.Drawing.Color]::FromArgb(240, 233, 224)
    $snooze.ForeColor    = [System.Drawing.Color]::FromArgb(90, 75, 60)
    $snooze.FlatAppearance.BorderSize = 0
    $form.Controls.Add($snooze)

    $form.AcceptButton = $ok

    # Come to the front even if something else is fullscreen.
    $form.Add_Shown({
        $form.Activate()
        $form.BringToFront()
        [System.Media.SystemSounds]::Asterisk.Play()
    })

    $result = $form.ShowDialog()
    $form.Dispose()
    return $result
}

try {
    if ($TestNow) {
        Show-JuiceReminder | Out-Null
        return
    }

    $wait = $IntervalMinutes
    while ($true) {
        Start-Sleep -Seconds ($wait * 60)
        $answer = Show-JuiceReminder
        if ($answer -eq [System.Windows.Forms.DialogResult]::Retry) {
            $wait = $SnoozeMinutes
        } else {
            $wait = $IntervalMinutes
        }
    }
}
finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}

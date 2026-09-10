# Juice Reminder

A small Windows tray-less nag: every hour it pops up an always-on-top window
reminding you to have a drink of your juice. Dismiss it and the hour starts again.

## Files

| File | Purpose |
| --- | --- |
| `JuiceReminder.ps1` | The program. Sleeps for the interval, shows the popup, repeats. |
| `Start-JuiceReminder.vbs` | Launches the script with no visible console window. |
| `Build-Installer.ps1` | Builds `dist\JuiceReminderSetup.exe`. |
| `installer\JuiceReminder.iss` | Inno Setup script for the installer. |
| `tools\New-JuiceIcon.ps1` | Draws `assets\juice.ico`, so no binary artwork lives in the repo. |
| `Install-Autostart.ps1` | Script-only install: adds a Startup-folder shortcut. |
| `Uninstall-Autostart.ps1` | Removes that shortcut and stops any running copy. |

## Install

Run `JuiceReminderSetup.exe`. It is a per-user install, so there is no UAC
prompt: files go to `%LocalAppData%\Programs\Juice Reminder`, with a Start Menu
entry, an uninstall entry in Add/Remove Programs, and a tick-box for starting at
login (on by default).

### Or without the installer

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-Autostart.ps1
```

Starts automatically at the next login. To start it immediately without logging
out, double-click `Start-JuiceReminder.vbs`.

## Build the installer

Needs Inno Setup 6:

```powershell
winget install --id JRSoftware.InnoSetup
powershell -NoProfile -ExecutionPolicy Bypass -File .\Build-Installer.ps1
```

Regenerates the icon and writes `dist\JuiceReminderSetup.exe` (~2.3 MB).

## Preview the popup

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\JuiceReminder.ps1 -TestNow
```

## Uninstall

If you used the setup program, uninstall from Add/Remove Programs or the Start
Menu shortcut. It stops the running copy and removes the login entry.

For a script-only install:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-Autostart.ps1
```

## Settings

Edit the `param()` block at the top of `JuiceReminder.ps1` (in the install
folder if you used the setup program):

- `$IntervalMinutes` - minutes between reminders (default 60)
- `$SnoozeMinutes` - minutes to wait after Snooze (default 10)

Restart the reminder after changing them.

## Behaviour notes

- The popup has no close button, so it can only be dismissed with **OK** or
  **Snooze**.
- A global mutex keeps a single instance running, so a double launch is a no-op.
- Reminders only fire while the machine is on and you are logged in; the timer
  does not try to catch up on missed hours.

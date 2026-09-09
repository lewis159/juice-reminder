# Juice Reminder

A small Windows tray-less nag: every hour it pops up an always-on-top window
reminding you to have a drink of your juice. Dismiss it and the hour starts again.

## Files

| File | Purpose |
| --- | --- |
| `JuiceReminder.ps1` | The program. Sleeps for the interval, shows the popup, repeats. |
| `Start-JuiceReminder.vbs` | Launches the script with no visible console window. |
| `Install-Autostart.ps1` | Creates a Startup-folder shortcut so it runs at every login. |
| `Uninstall-Autostart.ps1` | Removes the shortcut and stops any running copy. |

## Install

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-Autostart.ps1
```

Starts automatically at the next login. To start it immediately without logging
out, double-click `Start-JuiceReminder.vbs`.

## Preview the popup

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\JuiceReminder.ps1 -TestNow
```

## Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-Autostart.ps1
```

## Settings

Edit the `param()` block at the top of `JuiceReminder.ps1`:

- `$IntervalMinutes` - minutes between reminders (default 60)
- `$SnoozeMinutes` - minutes to wait after Snooze (default 10)

Restart the reminder after changing them.

## Behaviour notes

- The popup has no close button, so it can only be dismissed with **OK** or
  **Snooze**.
- A global mutex keeps a single instance running, so a double launch is a no-op.
- Reminders only fire while the machine is on and you are logged in; the timer
  does not try to catch up on missed hours.

# Juice Reminder

A small Windows 10/11 nag: every hour it pops up an always-on-top window
reminding you to have a drink of your juice. Click **OK** and the hour starts
again, or **Snooze** for 10 minutes.

## Install

Download `JuiceReminderSetup.exe` from the
[latest release](https://github.com/lewis159/juice-reminder/releases/latest) and
run it.

- Per-user install, so no admin prompt. Files go to
  `%LocalAppData%\Programs\Juice Reminder`.
- Adds a Start Menu group (reminder, log folder, uninstall) and an entry in
  Add/Remove Programs.
- "Start automatically when I log in" is ticked by default.
- The installer is unsigned, so SmartScreen may say "unknown publisher":
  choose **More info**, then **Run anyway**.

### Upgrading

Just run the newer setup program over the top. It stops the running reminder
first.

If you previously set it up with the old `Install-Autostart.ps1` script, the
installer finds that automatically: it stops any copy running from the old
location and deletes the old Startup shortcut, then records what it removed in
the log. Nothing to do by hand.

## Log

Everything is written to `C:\JuiceReminder\logs\juice-reminder.log`
(Start Menu → Juice Reminder → Juice Reminder log):

```
2026-09-11 09:00:02 [INFO] Started v1.1.0 (PID 18360). Every 60 min, snooze 10 min. Script: ...
2026-09-11 10:00:02 [INFO] Reminder shown.
2026-09-11 10:00:09 [INFO] OK clicked after 7 s. Next reminder in 60 min.
2026-09-11 11:00:09 [INFO] [setup] Install v1.1.0 started. Install folder: ...
2026-09-11 11:00:09 [INFO] [setup] Removed old script-install Startup shortcut 'Juice Reminder.lnk' ...
```

Lines tagged `[setup]` come from the installer or uninstaller. The file rolls
over to `juice-reminder.log.1` at 1 MB. Logs are kept when you uninstall; delete
`C:\JuiceReminder` yourself if you don't want them.

## Preview the popup

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\Juice Reminder\JuiceReminder.ps1" -TestNow
```

Works even while the reminder is running.

## Settings

Edit the `param()` block at the top of the installed `JuiceReminder.ps1`:

- `$IntervalMinutes` - minutes between reminders (default 60)
- `$SnoozeMinutes` - minutes to wait after Snooze (default 10)
- `$LogDir` - log folder (default `C:\JuiceReminder\logs`)

Then sign out and back in, or re-run the setup program with "Start Juice
Reminder now" ticked. Re-installing overwrites the file, so re-apply your edits
after an upgrade.

## Uninstall

Add/Remove Programs → Juice Reminder, or Start Menu → Uninstall Juice Reminder.
It stops the running reminder and removes the login entry.

## Behaviour notes

- The popup has no close button, so it can only be dismissed with **OK** or
  **Snooze**.
- A single-instance lock means a second launch just logs and exits.
- Reminders only fire while you are logged in; missed hours are not caught up.

## Development

| Path | Purpose |
| --- | --- |
| `JuiceReminder.ps1` | The program. `$AppVersion` in here is the single source of the version. |
| `Start-JuiceReminder.vbs` | Launches the script with no visible console window. |
| `installer\JuiceReminder.iss` | Inno Setup script. |
| `installer\SetupHelper.ps1` | Run by setup/uninstall: stops running copies, removes the old script install, logs. |
| `tools\New-JuiceIcon.ps1` | Draws `assets\juice.ico`, so no binary artwork lives in the repo. |
| `Build-Installer.ps1` | Builds `dist\JuiceReminderSetup.exe`. |
| `docs\claude-prompt.md` | Prompt to hand a new Claude session working on this project. |

Build (needs Inno Setup 6):

```powershell
winget install --id JRSoftware.InnoSetup
powershell -NoProfile -ExecutionPolicy Bypass -File .\Build-Installer.ps1
```

To release: bump `$AppVersion`, build, commit, then
`gh release create vX.Y.Z dist\JuiceReminderSetup.exe`.

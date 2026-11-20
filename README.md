# Juice Reminder

A small Windows 10/11 nag: every 30 minutes, hour or 2 hours (your choice) it
pops up an always-on-top window, with a sound, reminding you to have a drink of
your juice. Click **OK** and the wait starts again, or **Snooze** for a few
minutes. It sits in the system tray while it waits.

## Install

Download `JuiceReminderSetup.exe` from the
[latest release](https://github.com/lewis159/juice-reminder/releases/latest) and
run it.

- Per-user install, so no admin prompt. Files go to
  `%LocalAppData%\Programs\Juice Reminder`.
- Adds a Start Menu group (reminder, settings, log folder, uninstall) and an
  entry in Add/Remove Programs.
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

Settings are stored outside the install folder, so upgrades keep them.

From 1.2.0 the log moved from `C:\JuiceReminder\logs` to
`%LocalAppData%\JuiceReminder\logs`. The old folder is left alone; delete
`C:\JuiceReminder` if you don't need the old log.

## Tray icon

While it waits, a juice glass sits in the system tray (you may need the **^**
arrow next to the clock). Hover it to see when the next reminder is due.
Right-click for:

- **Remind me now**
- **Pause reminders** - click again to resume (the wait restarts). Pausing lasts
  until you resume or sign out.
- **Settings...** (also: double-click the icon)
- **Open log folder**
- **Exit** - stops reminders until you next sign in or start it from the Start
  Menu.

## Settings

Open them from the tray icon, or Start Menu → Juice Reminder → **Juice Reminder
settings**:

- **Remind me every** - 30 minutes, 1 hour (default) or 2 hours.
- **Snooze for** - 5, 10 (default), 15 or 30 minutes.
- **Play a sound** - any sound from `C:\Windows\Media`, or **Browse...** for your
  own `.wav`, `.mp3`, `.wma` or `.m4a`. Set the volume, choose whether it keeps
  repeating until you click OK or Snooze, and use **Preview** to hear it.

Changes apply to the running reminder within 15 seconds, no restart needed. A
new interval counts from the last reminder, so shortening it can bring the next
one forward.

They are saved in `%AppData%\JuiceReminder\settings.json`, which you can also
edit by hand:

```json
{
  "IntervalMinutes": 60,
  "SnoozeMinutes": 10,
  "SoundEnabled": true,
  "SoundPath": "C:\\Windows\\Media\\Windows Notify System Generic.wav",
  "SoundVolume": 80,
  "SoundRepeat": false
}
```

`IntervalMinutes` must be 30, 60 or 120 and `SnoozeMinutes` 1 to 120; anything
invalid is ignored (default used) and noted in the log. If the sound file is
missing, the standard Windows chime plays instead.

## Log

Everything is written to `%LocalAppData%\JuiceReminder\logs\juice-reminder.log`
(tray icon → Open log folder, or Start Menu → Juice Reminder → Juice Reminder
log):

```
2026-11-20 09:00:02 [INFO] Started v1.2.0 (PID 18360). Every 60 min, snooze 10 min, sound 'Windows Notify System Generic.wav' at 80%. Settings: ...
2026-11-20 10:00:02 [INFO] Reminder shown (timer).
2026-11-20 10:00:09 [INFO] OK clicked after 7 s. Next reminder in 60 min.
2026-11-20 10:20:41 [INFO] Settings saved. Every 30 min, snooze 10 min, sound 'tada.wav' at 60%.
2026-11-20 12:14:05 [INFO] Reminder shown 43 min late (was due 11:31; PC was probably asleep or locked).
2026-11-20 13:00:09 [INFO] [setup] Install v1.2.0 started. Install folder: ...
```

Lines tagged `[setup]` come from the installer or uninstaller. The file rolls
over to `juice-reminder.log.1` at 1 MB. Logs and settings are kept when you
uninstall; delete `%LocalAppData%\JuiceReminder` and `%AppData%\JuiceReminder`
yourself if you don't want them.

## Preview the popup

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\Juice Reminder\JuiceReminder.ps1" -TestNow
```

Works even while the reminder is running, and uses your current settings
(including the sound).

## Uninstall

Add/Remove Programs → Juice Reminder, or Start Menu → Uninstall Juice Reminder.
It stops the running reminder and removes the login entry.

## Behaviour notes

- The popup has no close button, so it can only be dismissed with **OK** or
  **Snooze**.
- One copy per signed-in user: a second launch just logs and exits. Other
  users on the same PC get their own.
- The wait is measured against the clock, so after the PC wakes from sleep an
  overdue reminder shows straight away (once; missed ones are not stacked up).
- Reminders only fire while you are logged in.
- If a reminder ever fails, it is logged and the next one is scheduled as
  normal; the app keeps running.

## Development

| Path | Purpose |
| --- | --- |
| `JuiceReminder.ps1` | The program. `$AppVersion` in here is the single source of the version. |
| `Start-JuiceReminder.vbs` | Launches the script with no visible console window; passes arguments through (e.g. `-Settings`). |
| `installer\JuiceReminder.iss` | Inno Setup script. |
| `installer\SetupHelper.ps1` | Run by setup/uninstall: stops running copies, removes the old script install, logs. |
| `tools\New-JuiceIcon.ps1` | Draws `assets\juice.ico`, so no binary artwork lives in the repo. |
| `Build-Installer.ps1` | Builds `dist\JuiceReminderSetup.exe`. |
| `docs\claude-prompt.md` | Prompt to hand a new Claude session working on this project. |

Script switches: `-TestNow` (one popup), `-Settings` (settings window),
`-SettingsPath` / `-LogDir` (use other files, handy for testing) and
`-StartDelaySeconds N` (first reminder after N seconds). Dot-sourcing the script
(`. .\JuiceReminder.ps1`) loads its functions without starting it.

Build (needs Inno Setup 6):

```powershell
winget install --id JRSoftware.InnoSetup
powershell -NoProfile -ExecutionPolicy Bypass -File .\Build-Installer.ps1
```

To release: bump `$AppVersion`, build, commit, then
`gh release create vX.Y.Z dist\JuiceReminderSetup.exe`.

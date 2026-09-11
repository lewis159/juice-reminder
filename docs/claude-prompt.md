# Prompt for a new Claude session

Paste everything below the line into a new Claude Code session opened in
`C:\dev\juice-reminder`, then add what you want changed at the end.

---

You're working on **Juice Reminder**, a small Windows desktop utility I use to
remind someone to drink their juice. Repo: `C:\dev\juice-reminder`, public on
GitHub at `lewis159/juice-reminder`. Target machines run Windows 10 (my dev box
is Windows 11). Read `README.md` first, then the files it lists.

## What it does

- Every 60 minutes it shows an always-on-top, centered popup: a drawn glass of
  juice, "Time for a drink of your juice", and two buttons, **OK** (next reminder
  in 60 min) and **Snooze 10 min**. No close button. A soft system chime plays.
- It starts at login and runs silently in the background, one instance only.
- It logs to `C:\JuiceReminder\logs\juice-reminder.log` (start, each popup,
  button pressed and how long it took, stop, errors; rolls over at 1 MB).
- It ships as `JuiceReminderSetup.exe`, a per-user Inno Setup installer (no UAC)
  that installs to `%LocalAppData%\Programs\Juice Reminder`, adds Start Menu
  entries, an Add/Remove Programs uninstaller, and an optional Startup shortcut.
- The installer silently removes the old pre-installer setup (a Startup
  shortcut made by a now-deleted `Install-Autostart.ps1` pointing outside the
  install folder, plus any copy running from there) and logs what it removed.

## How it's built

- `JuiceReminder.ps1`: PowerShell 5.1 + WinForms. `$AppVersion` near the top is
  the single source of truth for the version.
- `Start-JuiceReminder.vbs`: runs the script with `-WindowStyle Hidden` so no
  console flashes.
- `installer\JuiceReminder.iss`: Inno Setup 6 script. `installer\SetupHelper.ps1`
  is called from its `[Code]` section on install and uninstall.
- `tools\New-JuiceIcon.ps1`: draws `assets\juice.ico` with GDI+ at build time.
  The .ico is gitignored.
- `Build-Installer.ps1`: reads `$AppVersion`, regenerates the icon, runs
  `ISCC.exe /DAppVersion=...`, writes `dist\JuiceReminderSetup.exe` and prints its
  SHA-256. Inno Setup lives at `%LocalAppData%\Programs\Inno Setup 6\ISCC.exe`.

## Gotchas already hit, don't reintroduce them

- Keep `.ps1` files plain ASCII. Windows PowerShell 5.1 reads BOM-less files as
  ANSI, so emoji or smart quotes turn into garbage. Draw graphics in code instead.
- `$PSScriptRoot` and `$MyInvocation` are empty inside `param()` defaults.
  Resolve script-relative paths in the script body.
- When finding the running reminder, only stop a `powershell.exe` whose `-File`
  argument is a real, existing `JuiceReminder.ps1` (see `Get-ReminderScriptPath`
  in `installer\SetupHelper.ps1`), and skip `$PID`. A plain `-like` on the
  command line also kills unrelated shells whose command text merely contains
  the pattern; that has happened.
- Write ICO entries as classic DIB, not PNG. GDI+ readers reject PNG entries.
- `-TestNow` must not take the single-instance mutex, or the preview silently
  does nothing while the real reminder runs.
- Logging must never throw. Wrap it and swallow failures.

## How I want you to work

- Ask me questions when a choice would materially change the result; otherwise
  make a sensible call and tell me what you assumed.
- Test for real on this machine before calling anything done: parse-check the
  scripts, build the installer, run it (`/VERYSILENT /TASKS=startupicon` is fine),
  and check the files, shortcuts, Add/Remove entry, running process and log.
- Bump `$AppVersion` (semver) for each release. Commit with Conventional Commits
  messages and push to `main`.
- You're pre-authorised to create a GitHub release for each new build
  (`gh release create vX.Y.Z dist\JuiceReminderSetup.exe`) with short notes and
  the SHA-256. Ask before anything else outward-facing, like changing repo
  visibility or deleting releases.
- Keep README.md and this prompt up to date when behaviour changes.

## What I want changed

<describe the change here>

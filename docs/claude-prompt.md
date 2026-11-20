# Prompt for a new Claude session

Paste everything below the line into a new Claude Code session opened in
`C:\dev\juice-reminder`, then add what you want changed at the end.

---

You're working on **Juice Reminder**, a small Windows desktop utility I use to
remind someone to drink their juice. Repo: `C:\dev\juice-reminder`, public on
GitHub at `lewis159/juice-reminder`. Target machines run Windows 10 (my dev box
is Windows 11). Read `README.md` first, then the files it lists.

## What it does

- Every 30 min, 1 hour or 2 hours (user's choice) it shows an always-on-top,
  centered popup: a drawn glass of juice, "Time for a drink of your juice", and
  two buttons, **OK** (next reminder after a full interval) and **Snooze N min**.
  No close button. A configurable sound plays (Windows sound or the user's own
  file, volume, optional repeat until dismissed).
- It starts at login and sits in the system tray (Remind me now, Pause,
  Settings..., Open log folder, Exit), one instance per user.
- Settings live in `%AppData%\JuiceReminder\settings.json`, edited through a
  settings window (tray, Start Menu, or `-Settings`). The running app re-reads
  the file within 15 s of it changing.
- It logs to `%LocalAppData%\JuiceReminder\logs\juice-reminder.log` (start,
  each popup, button pressed and how long it took, settings changes, stop,
  errors; rolls over at 1 MB). Before 1.2.0 the log was in `C:\JuiceReminder\logs`.
- It updates itself (from 1.3.0): checks `latest.json` on the latest GitHub
  release 2 min after start and daily, downloads the installer, verifies its
  SHA-256, and runs it with `/VERYSILENT /RESTARTAPP=1` (Auto: after the next
  OK click; Notify: when the user clicks Install). Network work runs in a
  background runspace polled by the 15 s timer.
- From 1.4.0 the installer is Authenticode-signed with a self-signed
  certificate (`CN=Juice Reminder Release Signing`, thumbprint
  `4D1E8C6F2D423271B9A0E70A3127F38A353C63B2`) whose key is in
  `Cert:\CurrentUser\My` on the release machine. `Build-Installer.ps1` signs
  before hashing. The updater only installs files signed by a thumbprint in
  `$TrustedSignerThumbprints` (`JuiceReminder.ps1`).
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
- WinForms event handlers find the form's controls through PowerShell's
  dynamic scoping, which only works while the function that called
  `ShowDialog()` is still running. Keep "build the form" and "show it" in one
  function, and don't use `GetNewClosure()`: closures can't see the script's
  functions or `$script:` variables.
- Don't name a script-scope variable after a script parameter, even with a
  `$script:` prefix (`$script:settings` is the `[switch]$Settings` parameter and
  assigning an object to it crashes). App state is `$script:appSettings`.
- Don't wait with `Start-Sleep` for a whole interval: sleep timers pause while
  the PC sleeps. The tray app checks the clock on a 15 s WinForms timer.
- Test the tray app headlessly with `-SettingsPath`, `-LogDir` and
  `-StartDelaySeconds`; the popup's buttons can be clicked with `BM_CLICK` on
  their window handles (UI Automation sees them as panes, not buttons).
  Stop the installed copy first: it holds the single-instance lock, so a test
  copy would just log "already running" and exit.
- Test updates with a local `HttpListener` on `http://localhost:<port>/`
  serving `latest.json` and the installer, and `UpdateUrl` pointing at it
  (plain http is allowed only for loopback). `-UpdateCheckDelaySeconds 5`
  makes the first check quick.
- Every release must upload `dist\latest.json` as well as the installer, or
  installed copies never see it.
- A file signed by our self-signed certificate reports `Get-AuthenticodeSignature`
  status `UnknownError` (untrusted root), not `Valid`; that's expected and
  `Test-InstallerSignature` accepts it only for a pinned, self-issued signer. A
  changed file reports `HashMismatch`. Don't "fix" this by requiring `Valid`.
- Never release an `-AllowUnsigned` build, never commit a `.pfx`, and never
  remove the current thumbprint from `$TrustedSignerThumbprints` without
  shipping its replacement first (see README "Signing key").

## How I want you to work

- Ask me questions when a choice would materially change the result; otherwise
  make a sensible call and tell me what you assumed.
- Test for real on this machine before calling anything done: parse-check the
  scripts, build the installer, run it (`/VERYSILENT /TASKS=startupicon` is fine),
  and check the files, shortcuts, Add/Remove entry, running process and log.
- Bump `$AppVersion` (semver) for each release. Commit with Conventional Commits
  messages and push to `main`.
- You're pre-authorised to create a GitHub release for each new build
  (`gh release create vX.Y.Z dist\JuiceReminderSetup.exe dist\latest.json`)
  with short notes and the SHA-256. Ask before anything else outward-facing, like changing repo
  visibility or deleting releases.
- Keep README.md and this prompt up to date when behaviour changes.

## What I want changed

<describe the change here>

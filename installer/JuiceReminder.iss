; Inno Setup script for Juice Reminder.
; Build with: powershell -File ..\Build-Installer.ps1

#define AppName        "Juice Reminder"
#define AppVersion     "1.0.0"
#define AppPublisher   "Ben Percival"
#define AppUrl         "https://github.com/lewis159/juice-reminder"
#define LauncherVbs    "Start-JuiceReminder.vbs"

[Setup]
AppId={{F2A6D5D0-9690-4E54-AAC9-F803604EEE80}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppSupportURL={#AppUrl}
AppUpdatesURL={#AppUrl}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; Per-user install, so no UAC prompt and no admin account needed.
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=JuiceReminderSetup
SetupIconFile=..\assets\juice.ico
UninstallDisplayIcon={app}\juice.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "startupicon"; Description: "Start Juice Reminder automatically when I log in"; GroupDescription: "Startup:"

[Files]
Source: "..\JuiceReminder.ps1";        DestDir: "{app}"; Flags: ignoreversion
Source: "..\Start-JuiceReminder.vbs";  DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md";                DestDir: "{app}"; Flags: ignoreversion
Source: "..\assets\juice.ico";         DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\{#LauncherVbs}"""; \
    WorkingDir: "{app}"; IconFilename: "{app}\juice.ico"; Comment: "Hourly reminder to drink your juice"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{userstartup}\{#AppName}"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\{#LauncherVbs}"""; \
    WorkingDir: "{app}"; IconFilename: "{app}\juice.ico"; Tasks: startupicon

[Run]
Filename: "{sys}\wscript.exe"; Parameters: """{app}\{#LauncherVbs}"""; WorkingDir: "{app}"; \
    Description: "Start Juice Reminder now"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: files; Name: "{userstartup}\{#AppName}.lnk"

[Code]
{ Stops any copy of the reminder that is already running, so an upgrade or an
  uninstall is not left fighting a process that holds the old script open. }
procedure StopRunningReminder();
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{cmd}'), '/C taskkill /F /FI "IMAGENAME eq powershell.exe" ' +
       '/FI "WINDOWTITLE eq Juice time" >nul 2>&1', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
       '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "Get-CimInstance Win32_Process ' +
       '-Filter ""Name = ''powershell.exe''"" | Where-Object { $_.CommandLine -like ''*-File *JuiceReminder.ps1*'' } | ' +
       'ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"',
       '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
    StopRunningReminder();
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    StopRunningReminder();
end;

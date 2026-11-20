; Inno Setup script for Juice Reminder.
; Build with: powershell -File ..\Build-Installer.ps1
; (the build script passes /DAppVersion=... read from JuiceReminder.ps1)

#ifndef AppVersion
  #define AppVersion "0.0.0-dev"
#endif

#define AppName        "Juice Reminder"
#define AppPublisher   "Ben Percival"
#define AppUrl         "https://github.com/lewis159/juice-reminder"
#define LauncherVbs    "Start-JuiceReminder.vbs"
#define HelperScript   "SetupHelper.ps1"

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
VersionInfoVersion={#AppVersion}
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
; Installed so the uninstaller can use it too; also extracted early during setup.
Source: "{#HelperScript}";             DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\{#LauncherVbs}"""; \
    WorkingDir: "{app}"; IconFilename: "{app}\juice.ico"; Comment: "Reminder to drink your juice"
Name: "{group}\Juice Reminder settings"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\{#LauncherVbs}"" -Settings"; \
    WorkingDir: "{app}"; IconFilename: "{app}\juice.ico"; Comment: "How often to remind you, and which sound to play"
Name: "{group}\Juice Reminder log"; Filename: "{localappdata}\JuiceReminder\logs"; Comment: "Folder containing juice-reminder.log"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{userstartup}\{#AppName}"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\{#LauncherVbs}"""; \
    WorkingDir: "{app}"; IconFilename: "{app}\juice.ico"; Tasks: startupicon

[Dirs]
; Logs are user data: created here, deliberately left behind on uninstall.
; (Settings live in %AppData%\JuiceReminder and are also kept.)
Name: "{localappdata}\JuiceReminder\logs"; Flags: uninsneveruninstall

[Run]
Filename: "{sys}\wscript.exe"; Parameters: """{app}\{#LauncherVbs}"""; WorkingDir: "{app}"; \
    Description: "Start Juice Reminder now"; Flags: nowait postinstall skipifsilent
; Self-update: the app runs setup with /VERYSILENT /RESTARTAPP=1, and this starts
; the new version once the files are in place.
Filename: "{sys}\wscript.exe"; Parameters: """{app}\{#LauncherVbs}"""; WorkingDir: "{app}"; \
    Flags: nowait; Check: ShouldRestartApp

[UninstallDelete]
Type: files; Name: "{userstartup}\{#AppName}.lnk"

[Code]
{ SetupHelper.ps1 does the real work (stopping running copies, removing the old
  script-based install) and logs it to %LocalAppData%\JuiceReminder\logs. }
procedure RunSetupHelper(const ScriptPath, Action: String);
var
  ResultCode: Integer;
begin
  if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + ScriptPath + '"' +
      ' -Action ' + Action +
      ' -InstallDir "' + ExpandConstant('{app}') + '"' +
      ' -Version "{#AppVersion}"',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Log('SetupHelper could not be started: ' + SysErrorMessage(ResultCode));
end;

function ShouldRestartApp: Boolean;
begin
  Result := WizardSilent and (ExpandConstant('{param:RESTARTAPP|0}') = '1');
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  { ssInstall runs before files and shortcuts are written, so old Startup
    shortcuts are gone before the new one is created. }
  if CurStep = ssInstall then
  begin
    ExtractTemporaryFile('{#HelperScript}');
    RunSetupHelper(ExpandConstant('{tmp}\{#HelperScript}'), 'Install');
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    RunSetupHelper(ExpandConstant('{app}\{#HelperScript}'), 'Uninstall');
end;

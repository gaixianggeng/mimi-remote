; Per-user Windows installer. Build with scripts/build-windows-installer.ps1.
#ifndef MyAppVersion
  #error MyAppVersion must be supplied by the build script
#endif
#ifndef SourceDir
  #error SourceDir must be supplied by the build script
#endif
#ifndef OutputDir
  #error OutputDir must be supplied by the build script
#endif
#ifndef MyOutputBaseFilename
  #error MyOutputBaseFilename must be supplied by the build script
#endif

#define MyAppName "Mimi Remote"
#define MyAppId "{{7D413E71-19C5-4F02-8AFC-437E1B8019FD}"

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=Mimi Remote
DefaultDirName={localappdata}\Programs\Mimi Remote
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
UsePreviousTasks=no
PrivilegesRequired=lowest
OutputDir={#OutputDir}
OutputBaseFilename={#MyOutputBaseFilename}
Compression=lzma2/ultra64
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\mimi-remote.ico
SetupIconFile=mimi-remote.ico
CloseApplications=yes
RestartApplications=no
#ifdef MySignTool
SignTool={#MySignTool}
SignedUninstaller=yes
#else
SignedUninstaller=no
#endif

[Files]
#ifdef MySignTool
Source: "{#SourceDir}\maintenance-identity.p7m"; DestDir: "{app}"; Flags: ignoreversion
#endif
Source: "{#SourceDir}\Mimi-Remote-Maintenance.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\agentd.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\mimi-agent-host.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\mimi-claude-adapter.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\alleycat-claude-bridge.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\mimi-remote-tray.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\mimi-tailcat-experiment.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\mimi-remote.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\THIRD_PARTY_NOTICES.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "register-service.ps1"; DestDir: "{tmp}"; Flags: dontcopy
Source: "configure-firewall.ps1"; DestDir: "{tmp}"; Flags: dontcopy

[Icons]
Name: "{userstartup}\Mimi Remote"; Filename: "{app}\mimi-remote-tray.exe"; WorkingDir: "{app}"; IconFilename: "{app}\mimi-remote.ico"
Name: "{group}\Mimi Remote"; Filename: "{app}\mimi-remote-tray.exe"; Parameters: "--show"; WorkingDir: "{app}"; IconFilename: "{app}\mimi-remote.ico"

[Tasks]
Name: "confirmworkspace"; Description: "Confirm a code folder for a new or pending workspace"; Flags: unchecked
Name: "lanfirewall"; Description: "Allow private LAN access (Private networks / LocalSubnet only)"; Flags: unchecked

[Run]
Filename: "{app}\mimi-remote-tray.exe"; Parameters: "--show"; Description: "Launch Mimi Remote in the notification area"; Flags: postinstall nowait skipifsilent

[Code]
function InstallDirectory: String;
begin
  Result := ExpandConstant('{app}');
end;

function AgentExecutable: String;
begin
  Result := InstallDirectory + '\agentd.exe';
end;

#include "installer-common.iss"

function InitializeSetup: Boolean;
begin
  Result := not IsAdmin;
  if not Result then
    SuppressibleMsgBox('Run Mimi Remote Setup as the current desktop user.', mbError, MB_OK, IDOK);
end;

procedure InitializeWizard;
begin
  AddWorkspacePage;
end;

procedure RemoveScheduledTask;
var
  ResultCode: Integer;
begin
  ExecConsoleHidden(ExpandConstant('{sys}\schtasks.exe'), '/delete /tn ' + Quote(TaskName) + ' /f', ResultCode);
end;

function ExecutableIsReleased(const Path: String): Boolean;
var
  Stream: TFileStream;
begin
  // Windows allows renaming a running image, so a rename probe cannot prove the
  // process exited. Opening it for exclusive write fails while it is mapped.
  Result := False;
  try
    Stream := TFileStream.Create(Path, fmOpenReadWrite or fmShareExclusive);
    Stream.Free;
    Result := True;
  except
    Result := False;
  end;
end;

procedure StopManagedService;
var
  ResultCode: Integer;
  Attempt: Integer;
  AgentPath: String;
begin
  AgentPath := ExpandConstant('{app}\agentd.exe');
  if not FileExists(AgentPath) then
    Exit;
  ExecConsoleHidden(AgentPath, 'stop', ResultCode);

  // schtasks /end returns before Windows has necessarily released the running
  // image, and a rename succeeds even while it is still mapped. Wait until the
  // image can be opened exclusively so upgrade/uninstall never replaces it early.
  for Attempt := 1 to 100 do begin
    if ExecutableIsReleased(AgentPath) then
      Exit;
    Sleep(100);
  end;
  RaiseException('Mimi Remote backend did not stop within 10 seconds.');
end;

procedure StopTrayApp;
var
  ResultCode: Integer;
  Attempt: Integer;
  TrayPath: String;
begin
  TrayPath := ExpandConstant('{app}\mimi-remote-tray.exe');
  if not FileExists(TrayPath) then
    Exit;

  ExecConsoleHidden(ExpandConstant('{sys}\taskkill.exe'), '/im "mimi-remote-tray.exe" /t', ResultCode);
  for Attempt := 1 to 30 do begin
    if ExecutableIsReleased(TrayPath) then
      Exit;
    Sleep(100);
  end;

  ExecConsoleHidden(ExpandConstant('{sys}\taskkill.exe'), '/im "mimi-remote-tray.exe" /t /f', ResultCode);
  for Attempt := 1 to 50 do begin
    if ExecutableIsReleased(TrayPath) then
      Exit;
    Sleep(100);
  end;
  RaiseException('Mimi Remote tray did not stop within 8 seconds.');
end;

procedure StopAgentHost;
var
  ResultCode: Integer;
  Attempt: Integer;
  HostPath: String;
begin
  // agentd 优雅退出后宿主会自行返回，先给它时间；仍未退出才强杀。
  // 宿主带 kill-on-close Job Object，强杀会连带清理 agentd 的进程树。
  HostPath := ExpandConstant('{app}\mimi-agent-host.exe');
  if not FileExists(HostPath) then
    Exit;

  for Attempt := 1 to 50 do begin
    if ExecutableIsReleased(HostPath) then
      Exit;
    Sleep(100);
  end;

  ExecConsoleHidden(ExpandConstant('{sys}\taskkill.exe'), '/im "mimi-agent-host.exe" /f', ResultCode);
  for Attempt := 1 to 50 do begin
    if ExecutableIsReleased(HostPath) then
      Exit;
    Sleep(100);
  end;
  RaiseException('Mimi Remote agent host did not stop within 10 seconds.');
end;

procedure StopTailcatHelper;
var
  ResultCode: Integer;
  Attempt: Integer;
  HelperPath: String;
begin
  // agentd asks the Tailcat helper to exit over its control socket, and the
  // managed service's kill-on-close Job Object removes it if agentd exits
  // first. Only force-stop a helper that is still running after that, such as
  // one left by a manually started "agentd serve".
  HelperPath := ExpandConstant('{app}\mimi-tailcat-experiment.exe');
  if not FileExists(HelperPath) then
    Exit;
  for Attempt := 1 to 50 do begin
    if ExecutableIsReleased(HelperPath) then
      Exit;
    Sleep(100);
  end;
  ExecConsoleHidden(ExpandConstant('{sys}\taskkill.exe'), '/im "mimi-tailcat-experiment.exe" /t /f', ResultCode);
  for Attempt := 1 to 50 do begin
    if ExecutableIsReleased(HelperPath) then
      Exit;
    Sleep(100);
  end;
  RaiseException('The Mimi Remote Tailcat helper did not stop within 10 seconds.');
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  PendingDirectory: String;
begin
  // Stop agentd gracefully before replacing files. The managed agent owns a
  // kill-on-close Job Object, so an unexpected exit also removes descendants.
  RequireExistingConfig := FileExists(ExpandConstant('{app}\agentd.exe'));
  if RequireExistingConfig then begin
    if RegQueryStringValue(HKCU, ProductRegistryKey, PendingBootstrapName, PendingDirectory) and
       (CompareText(PendingDirectory, InstallDirectory) = 0) then RequireExistingConfig := False;
  end else if not FileExists(ExpandConstant('{userappdata}\mimi-remote\config.json')) and
              not FileExists(ExpandConstant('{userappdata}\codex-ipad-agent\config.json')) then begin
    // If task registration fails after files are copied, retry the same first bootstrap.
    if not RegWriteStringValue(HKCU, ProductRegistryKey, PendingBootstrapName, InstallDirectory) then begin
      Result := 'Could not record the first-install state for the current user.';
      Exit;
    end;
  end;
  StopManagedService;
  StopAgentHost;
  StopTailcatHelper;
  StopTrayApp;
  // Keep the existing task registered while files are replaced. The
  // registration script uses Register-ScheduledTask -Force, so an upgrade
  // updates the task in place and Inno's file rollback can still leave the
  // previous service runnable if a later install step fails.
  Result := '';
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then begin
    DeleteFile(ExpandConstant('{group}\Mimi Remote Logs.lnk'));
    ApplyInstallerChoices;
  end;
end;

function InitializeUninstall: Boolean;
begin
  Result := not IsAdmin;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  FirewallMarker: Cardinal;
begin
  if CurUninstallStep = usUninstall then begin
    StopManagedService;
    StopAgentHost;
    StopTailcatHelper;
    StopTrayApp;
    RemoveScheduledTask;
    if RegQueryDWordValue(HKCU, ProductRegistryKey, FirewallMarkerName, FirewallMarker) and
       (FirewallMarker = 1) then begin
      if (not UninstallSilent) and RunMaintenance('disable-lan') then begin
        RegDeleteValue(HKCU, ProductRegistryKey, FirewallMarkerName);
        RegDeleteKeyIfEmpty(HKCU, ProductRegistryKey);
      end;
    end;
  end;
end;

// Agent configuration and logs deliberately live under %APPDATA% / %LOCALAPPDATA%
// and are never removed during installation or normal uninstall.

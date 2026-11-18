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
PrivilegesRequired=lowest
MinVersion=10.0.19045
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
Source: "{#SourceDir}\stop-desktop.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\agentd.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\mimi-agent-host.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\mimi-claude-adapter.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\alleycat-claude-bridge.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\app\*"; DestDir: "{app}\app"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceDir}\mimi-tailcat-experiment.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\mimi-remote.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\THIRD_PARTY_NOTICES.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "register-service.ps1"; DestDir: "{tmp}"; Flags: dontcopy
Source: "configure-firewall.ps1"; DestDir: "{tmp}"; Flags: dontcopy

[Icons]
Name: "{userstartup}\Mimi Remote"; Filename: "{app}\app\MimiRemote.exe"; Parameters: "--background"; WorkingDir: "{app}\app"; IconFilename: "{app}\mimi-remote.ico"; Check: DesktopStartupEnabled
Name: "{group}\Mimi Remote"; Filename: "{app}\app\MimiRemote.exe"; WorkingDir: "{app}\app"; IconFilename: "{app}\mimi-remote.ico"

[Tasks]
Name: "lanfirewall"; Description: "Allow private LAN access (Private networks / LocalSubnet only)"; Flags: unchecked

[Run]
Filename: "{app}\app\MimiRemote.exe"; Parameters: "--pair"; WorkingDir: "{app}\app"; Description: "Launch Mimi Remote"; Flags: postinstall nowait skipifsilent

[Code]
const
  TaskName = 'Mimi Remote agentd';
  FirewallRuleName = 'Mimi Remote agentd (Private LAN)';
  ProductRegistryKey = 'Software\Mimi Remote';
  FirewallMarkerName = 'PrivateLanFirewallRule';
  DesktopStartupMarker = 'DesktopStartupDisabled';
  PreviewRunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';
  PreviewRunValue = 'MimiRemoteNative';

var
  PostInstallFailed: Boolean;

function Quote(const Value: String): String;
begin
  Result := '"' + Value + '"';
end;

function ExecConsoleHidden(const Filename, Parameters: String; var ResultCode: Integer): Boolean;
var
  Output: TExecOutput;
begin
  // Inno Setup 6.4+ runs captured console commands without allocating a console.
  Result := ExecAndCaptureOutput(Filename, Parameters, '', SW_HIDE, ewWaitUntilTerminated, ResultCode, Output);
end;

procedure RemoveScheduledTask;
var
  ResultCode: Integer;
begin
  ExecConsoleHidden(ExpandConstant('{sys}\schtasks.exe'), '/delete /tn ' + Quote(TaskName) + ' /f', ResultCode);
end;

procedure RegisterScheduledTask;
var
  ResultCode: Integer;
  Parameters: String;
begin
  ExtractTemporaryFile('register-service.ps1');
  Parameters := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
    Quote(ExpandConstant('{tmp}\register-service.ps1')) + ' -HostPath ' +
    Quote(ExpandConstant('{app}\mimi-agent-host.exe')) + ' -LogPath ' +
    Quote(ExpandConstant('{localappdata}\Mimi Remote\logs\agentd.log')) +
    ' -TaskName ' + Quote(TaskName);
  if not ExecConsoleHidden(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Parameters, ResultCode) then begin
    PostInstallFailed := True;
    RaiseException('Unable to register the current-user login task (PowerShell could not be started).');
  end;
  if ResultCode <> 0 then begin
    PostInstallFailed := True;
    RaiseException('Unable to register the current-user login task. PowerShell returned ' + IntToStr(ResultCode) + '.');
  end;
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
  TrayPath, NativePath, ScriptPath, Parameters: String;
begin
  TrayPath := ExpandConstant('{app}\mimi-remote-tray.exe');
  NativePath := ExpandConstant('{app}\app\MimiRemote.exe');
  if not (FileExists(TrayPath) or FileExists(NativePath)) then
    Exit;
  if IsUninstaller then
    ScriptPath := ExpandConstant('{app}\stop-desktop.ps1')
  else begin
    ExtractTemporaryFile('stop-desktop.ps1');
    ScriptPath := ExpandConstant('{tmp}\stop-desktop.ps1');
  end;
  Parameters := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
    Quote(ScriptPath) + ' -InstallPath ' + Quote(AddBackslash(ExpandConstant('{app}')) + '.');
  if not ExecConsoleHidden(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Parameters, ResultCode) or
     (ResultCode <> 0) then begin
    RaiseException('Unable to stop the installed Mimi Remote client.');
  end;
  for Attempt := 1 to 50 do begin
    if ((not FileExists(TrayPath)) or ExecutableIsReleased(TrayPath)) and
       ((not FileExists(NativePath)) or ExecutableIsReleased(NativePath)) then
      Exit;
    Sleep(100);
  end;
  RaiseException('Mimi Remote client did not stop within 5 seconds.');
end;

function DesktopStartupEnabled: Boolean;
var
  Disabled: Cardinal;
begin
  Result := not (RegQueryDWordValue(HKCU, ProductRegistryKey, DesktopStartupMarker, Disabled) and (Disabled = 1));
end;

procedure FinalizeDesktopMigration;
var
  LegacyPath: String;
begin
  // A successful upgrade removes the marker the WinUI client uses to detect a downgrade.
  LegacyPath := ExpandConstant('{app}\mimi-remote-tray.exe');
  if FileExists(LegacyPath) and not DeleteFile(LegacyPath) then begin
    PostInstallFailed := True;
    RaiseException('Unable to remove the old Mimi Remote tray.');
  end;
  if (not DesktopStartupEnabled) and FileExists(ExpandConstant('{userstartup}\Mimi Remote.lnk')) and
     (not DeleteFile(ExpandConstant('{userstartup}\Mimi Remote.lnk'))) then begin
    PostInstallFailed := True;
    RaiseException('Unable to remove the disabled Mimi Remote login shortcut.');
  end;
  RegDeleteValue(HKCU, PreviewRunKey, PreviewRunValue);
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

procedure InitializeAndVerifyManagedService;
var
  ResultCode: Integer;
begin
  // 失败时在安装器对话框里给出服务日志位置。
  if not ExecConsoleHidden(ExpandConstant('{app}\agentd.exe'), 'up --no-pair --wait 60s', ResultCode) then begin
    PostInstallFailed := True;
    RaiseException('Unable to initialize Mimi Remote after installation. See ' + ExpandConstant('{localappdata}\Mimi Remote\logs\agentd.log') + ' for details.');
  end;
  if ResultCode <> 0 then begin
    PostInstallFailed := True;
    RaiseException('Mimi Remote did not become ready after installation. Logs: ' + ExpandConstant('{localappdata}\Mimi Remote\logs\agentd.log') + '. Re-run the previous signed installer to roll back.');
  end;
end;

procedure SetLANAccessPolicy(Enabled: Boolean);
var
  ResultCode: Integer;
  EnabledValue: String;
begin
  if Enabled then
    EnabledValue := 'true'
  else
    EnabledValue := 'false';
  if not ExecConsoleHidden(ExpandConstant('{app}\agentd.exe'),
    'network --lan-enabled=' + EnabledValue, ResultCode) then begin
    PostInstallFailed := True;
    RaiseException('Unable to apply the selected Windows LAN access policy.');
  end;
  if ResultCode <> 0 then begin
    PostInstallFailed := True;
    RaiseException('Unable to apply the selected Windows LAN access policy. agentd returned ' + IntToStr(ResultCode) + '.');
  end;
end;

procedure ConfigureLANAccess(Enabled: Boolean);
var
  ResultCode: Integer;
begin
  SetLANAccessPolicy(Enabled);
  if not ExecConsoleHidden(ExpandConstant('{app}\agentd.exe'),
    'restart --no-pair --wait 60s', ResultCode) then begin
    PostInstallFailed := True;
    RaiseException('Unable to restart Mimi Remote after applying the Windows LAN access policy.');
  end;
  if ResultCode <> 0 then begin
    PostInstallFailed := True;
    RaiseException('Mimi Remote did not become ready after applying the Windows LAN access policy.');
  end;
end;

procedure ConfigurePrivateLanFirewallRule(Enabled: Boolean);
var
  ResultCode: Integer;
  Parameters: String;
  Mode: String;
begin
  if Enabled then
    Mode := 'Enable'
  else
    Mode := 'Disable';
  ExtractTemporaryFile('configure-firewall.ps1');
  Parameters := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
    Quote(ExpandConstant('{tmp}\configure-firewall.ps1')) + ' -AgentPath ' +
    Quote(ExpandConstant('{app}\agentd.exe')) + ' -RuleName ' +
    Quote(FirewallRuleName) + ' -Mode ' + Mode;
  if not ShellExec('runas', ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    Parameters, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then begin
    PostInstallFailed := True;
    RaiseException('Unable to configure the optional private-LAN firewall rule.');
  end;
  if ResultCode <> 0 then begin
    PostInstallFailed := True;
    RaiseException('Unable to configure the optional private-LAN firewall rule. PowerShell returned ' + IntToStr(ResultCode) + '.');
  end;
  if Enabled then
    RegWriteDWordValue(HKCU, ProductRegistryKey, FirewallMarkerName, 1);
end;

function PrivateLanFirewallRuleIsValid: Boolean;
var
  ResultCode: Integer;
  Parameters: String;
begin
  ExtractTemporaryFile('configure-firewall.ps1');
  Parameters := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
    Quote(ExpandConstant('{tmp}\configure-firewall.ps1')) + ' -AgentPath ' +
    Quote(ExpandConstant('{app}\agentd.exe')) + ' -RuleName ' +
    Quote(FirewallRuleName) + ' -Mode Validate';
  Result := ExecConsoleHidden(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Parameters, ResultCode) and
    (ResultCode = 0);
end;

function PrivateLanNetworkProfileIsReady: Boolean;
var
  ResultCode: Integer;
  Parameters: String;
begin
  ExtractTemporaryFile('configure-firewall.ps1');
  Parameters := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
    Quote(ExpandConstant('{tmp}\configure-firewall.ps1')) + ' -AgentPath ' +
    Quote(ExpandConstant('{app}\agentd.exe')) + ' -RuleName ' +
    Quote(FirewallRuleName) + ' -Mode ValidateNetwork';
  Result := ExecConsoleHidden(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Parameters, ResultCode) and
    (ResultCode = 0);
end;

function GetCustomSetupExitCode: Integer;
begin
  if PostInstallFailed then
    Result := 1
  else
    Result := 0;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  // Stop agentd gracefully before replacing files. The managed agent owns a
  // kill-on-close Job Object, so an unexpected exit also removes descendants.
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
var
  FirewallMarker: Cardinal;
begin
  if CurStep = ssPostInstall then begin
    DeleteFile(ExpandConstant('{group}\Mimi Remote Logs.lnk'));
    // Validate the active network before registering or starting the new
    // service. An upgrade may carry an old allow_lan=true configuration, so
    // starting first would fail with a generic readiness error on Public Wi-Fi.
    if WizardIsTaskSelected('lanfirewall') and
       (not PrivateLanNetworkProfileIsReady) then begin
      PostInstallFailed := True;
      RaiseException('Private LAN access requires the current default Windows network profile to be Private. Only change a trusted Wi-Fi or Ethernet network to Private, then run Setup again.');
    end;
    // An upgrade can inherit prompt-created Public/Any rules. Repair the
    // firewall boundary before the first new service start, because the new
    // agent intentionally refuses to start with any unmanaged inbound Allow
    // rule targeting agentd.exe.
    if WizardIsTaskSelected('lanfirewall') then begin
      if not PrivateLanFirewallRuleIsValid then
        ConfigurePrivateLanFirewallRule(True);
      RegWriteDWordValue(HKCU, ProductRegistryKey, FirewallMarkerName, 1);
    end;
    // Existing installations may have an old wildcard configuration. Lock it
    // down before the first new service start when LAN access is not selected.
    if (not WizardIsTaskSelected('lanfirewall')) and
       FileExists(ExpandConstant('{userappdata}\mimi-remote\config.json')) then
      SetLANAccessPolicy(False);
    RegisterScheduledTask;
    InitializeAndVerifyManagedService;
    if WizardIsTaskSelected('lanfirewall') then begin
      ConfigureLANAccess(True);
    end else begin
      ConfigureLANAccess(False);
      if RegQueryDWordValue(HKCU, ProductRegistryKey, FirewallMarkerName, FirewallMarker) and
         (FirewallMarker = 1) then begin
        ConfigurePrivateLanFirewallRule(False);
        RegDeleteValue(HKCU, ProductRegistryKey, FirewallMarkerName);
        RegDeleteKeyIfEmpty(HKCU, ProductRegistryKey);
      end;
    end;
    FinalizeDesktopMigration;
  end;
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
    DeleteFile(ExpandConstant('{userstartup}\Mimi Remote.lnk'));
    RemoveScheduledTask;
    if RegQueryDWordValue(HKCU, ProductRegistryKey, FirewallMarkerName, FirewallMarker) and
       (FirewallMarker = 1) then begin
      ConfigurePrivateLanFirewallRule(False);
      RegDeleteValue(HKCU, ProductRegistryKey, FirewallMarkerName);
      RegDeleteKeyIfEmpty(HKCU, ProductRegistryKey);
    end;
  end;
end;

// Agent configuration and logs deliberately live under %APPDATA% / %LOCALAPPDATA%
// and are never removed during installation or normal uninstall.

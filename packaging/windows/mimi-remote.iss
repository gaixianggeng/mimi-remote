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
Source: "{#SourceDir}\agentd.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\alleycat-claude-bridge.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\mimi-remote-tray.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\mimi-remote.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "register-service.ps1"; DestDir: "{tmp}"; Flags: dontcopy
Source: "configure-firewall.ps1"; DestDir: "{tmp}"; Flags: dontcopy

[Icons]
Name: "{userstartup}\Mimi Remote"; Filename: "{app}\mimi-remote-tray.exe"; WorkingDir: "{app}"; IconFilename: "{app}\mimi-remote.ico"
Name: "{group}\Mimi Remote"; Filename: "{app}\mimi-remote-tray.exe"; Parameters: "--show"; WorkingDir: "{app}"; IconFilename: "{app}\mimi-remote.ico"
Name: "{group}\Mimi Remote Logs"; Filename: "{cmd}"; Parameters: "/k """"{app}\agentd.exe"" logs -n 200"""; WorkingDir: "{app}"; IconFilename: "{app}\mimi-remote.ico"

[Tasks]
Name: "lanfirewall"; Description: "Allow private LAN access (Private networks / LocalSubnet only)"; Flags: unchecked

[Run]
Filename: "{app}\mimi-remote-tray.exe"; Parameters: "--pair"; Description: "Launch Mimi Remote in the notification area"; Flags: postinstall nowait skipifsilent

[Code]
const
  TaskName = 'Mimi Remote agentd';
  FirewallRuleName = 'Mimi Remote agentd (Private LAN)';
  ProductRegistryKey = 'Software\Mimi Remote';
  FirewallMarkerName = 'PrivateLanFirewallRule';

var
  PostInstallFailed: Boolean;

function Quote(const Value: String): String;
begin
  Result := '"' + Value + '"';
end;

procedure RemoveScheduledTask;
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{sys}\schtasks.exe'), '/delete /tn ' + Quote(TaskName) + ' /f', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

procedure RegisterScheduledTask;
var
  ResultCode: Integer;
  Parameters: String;
begin
  ExtractTemporaryFile('register-service.ps1');
  Parameters := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
    Quote(ExpandConstant('{tmp}\register-service.ps1')) + ' -AgentPath ' +
    Quote(ExpandConstant('{app}\agentd.exe')) + ' -LogPath ' +
    Quote(ExpandConstant('{localappdata}\Mimi Remote\logs\agentd.log')) +
    ' -TaskName ' + Quote(TaskName);
  if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Parameters, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then begin
    PostInstallFailed := True;
    RaiseException('Unable to register the current-user login task (PowerShell could not be started).');
  end;
  if ResultCode <> 0 then begin
    PostInstallFailed := True;
    RaiseException('Unable to register the current-user login task. PowerShell returned ' + IntToStr(ResultCode) + '.');
  end;
end;

procedure StopManagedService;
var
  ResultCode: Integer;
  Attempt: Integer;
  AgentPath: String;
  ProbePath: String;
begin
  AgentPath := ExpandConstant('{app}\agentd.exe');
  if not FileExists(AgentPath) then
    Exit;
  Exec(AgentPath, 'stop', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  // schtasks /end returns before Windows has necessarily released the running
  // image. Probe with an atomic rename so upgrade/uninstall never continues
  // while agentd.exe is still locked.
  ProbePath := AgentPath + '.stop-check';
  for Attempt := 1 to 100 do begin
    if RenameFile(AgentPath, ProbePath) then begin
      if not RenameFile(ProbePath, AgentPath) then
        RaiseException('Mimi Remote stopped, but agentd.exe could not be restored after the shutdown check.');
      Exit;
    end;
    Sleep(100);
  end;
  RaiseException('Mimi Remote backend did not stop within 10 seconds.');
end;

procedure StopTrayApp;
var
  ResultCode: Integer;
  Attempt: Integer;
  TrayPath: String;
  ProbePath: String;
begin
  TrayPath := ExpandConstant('{app}\mimi-remote-tray.exe');
  if not FileExists(TrayPath) then
    Exit;

  Exec(ExpandConstant('{sys}\taskkill.exe'), '/im "mimi-remote-tray.exe" /t', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  ProbePath := TrayPath + '.stop-check';
  for Attempt := 1 to 30 do begin
    if RenameFile(TrayPath, ProbePath) then begin
      if not RenameFile(ProbePath, TrayPath) then
        RaiseException('Mimi Remote tray stopped, but its executable could not be restored after the shutdown check.');
      Exit;
    end;
    Sleep(100);
  end;

  Exec(ExpandConstant('{sys}\taskkill.exe'), '/im "mimi-remote-tray.exe" /t /f', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  for Attempt := 1 to 50 do begin
    if RenameFile(TrayPath, ProbePath) then begin
      if not RenameFile(ProbePath, TrayPath) then
        RaiseException('Mimi Remote tray stopped, but its executable could not be restored after the forced shutdown check.');
      Exit;
    end;
    Sleep(100);
  end;
  RaiseException('Mimi Remote tray did not stop within 8 seconds.');
end;

procedure InitializeAndVerifyManagedService;
var
  ResultCode: Integer;
begin
  if not Exec(ExpandConstant('{app}\agentd.exe'), 'up --no-pair', '', SW_SHOW, ewWaitUntilTerminated, ResultCode) then begin
    PostInstallFailed := True;
    RaiseException('Unable to initialize Mimi Remote after installation.');
  end;
  if ResultCode <> 0 then begin
    PostInstallFailed := True;
    RaiseException('Mimi Remote did not become ready after installation. Re-run the previous signed installer to roll back.');
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
  if not Exec(ExpandConstant('{app}\agentd.exe'),
    'network --lan-enabled=' + EnabledValue,
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then begin
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
  if not Exec(ExpandConstant('{app}\agentd.exe'),
    'restart --no-pair',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then begin
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
  Result := Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    Parameters, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and
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
  Result := Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    Parameters, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and
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
  StopTrayApp;
  StopManagedService;
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
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  FirewallMarker: Cardinal;
begin
  if CurUninstallStep = usUninstall then begin
    StopTrayApp;
    StopManagedService;
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
// and are not listed in [InstallDelete], so normal uninstall preserves user state.

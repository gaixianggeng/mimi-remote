const
  TaskName = 'Mimi Remote agentd';
  ProductRegistryKey = 'Software\Mimi Remote';
  FirewallMarkerName = 'PrivateLanFirewallRule';
  PendingBootstrapName = 'InitialBootstrapPending';
  MaintenanceUacCancelledExitCode = 1223;

var
  PostInstallFailed, RequireExistingConfig, DirectoryConfirmed, MaintenanceUacCancelled: Boolean;
  LastMaintenanceExitCode: Integer;
  WorkspacePage: TInputDirWizardPage;

function Quote(const Value: String): String;
begin
  Result := '"' + Value + '"';
end;

function ExecConsoleHidden(const Filename, Parameters: String; var ResultCode: Integer): Boolean;
var
  Output: TExecOutput;
begin
  // Inno Setup 6.4+ runs captured console commands without allocating a console.
  Result := ExecAndCaptureOutput(Filename, Parameters, ExpandConstant('{sys}'), SW_HIDE, ewWaitUntilTerminated, ResultCode, Output);
end;

procedure RegisterScheduledTask;
var
  ResultCode: Integer;
  Parameters: String;
begin
  ExtractTemporaryFile('register-service.ps1');
  Parameters := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
    Quote(ExpandConstant('{tmp}\register-service.ps1')) + ' -HostPath ' +
    Quote((InstallDirectory + '\mimi-agent-host.exe')) + ' -LogPath ' +
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

procedure AddWorkspacePage;
begin
  WorkspacePage := CreateInputDirPage(wpSelectTasks, 'Confirm your workspace', 'Choose the folder your phone may access.',
    'For a new or pending setup, choose an existing folder to confirm scanning and browsing. Existing confirmed grants are preserved.', False, '');
  WorkspacePage.Add('Code folder:');
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if WorkspacePage <> nil then
    if PageID = WorkspacePage.ID then
      Result := WizardSilent or (not WizardIsTaskSelected('confirmworkspace'));
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Root: String;
begin
  Result := True;
  if WorkspacePage = nil then Exit;
  if CurPageID <> WorkspacePage.ID then Exit;
  Root := WorkspacePage.Values[0];
  if (Root = '') or (Pos('"', Root) <> 0) or (not DirExists(Root)) or (ExtractFileDrive(Root) = '') then begin
    MsgBox('Choose an existing folder using its full path.', mbError, MB_OK);
    Result := False;
  end;
  DirectoryConfirmed := Result;
end;

// UI-4/UI-5 call only the release-matched, authenticated agentd broker:
// installer-maintenance modify. No registry command, caller path or uninstaller.
function RunMaintenance(const Action: String): Boolean;
var
  Code: Integer;
begin
  if ExecConsoleHidden(AgentExecutable, 'installer-maintenance ' + Action, Code) then begin
    LastMaintenanceExitCode := Code;
    Result := Code = 0;
  end else begin
    LastMaintenanceExitCode := -1;
    Result := False;
  end;
end;

function FirewallCheck(const Mode: String): Boolean;
var
  Code: Integer;
  Parameters: String;
begin
  ExtractTemporaryFile('configure-firewall.ps1');
  Parameters := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
    Quote(ExpandConstant('{tmp}\configure-firewall.ps1')) + ' -AgentPath ' + Quote(InstallDirectory + '\agentd.exe') + ' -Mode ' + Mode;
  Result := ExecConsoleHidden(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Parameters, Code) and (Code = 0);
end;

function GetCustomSetupExitCode: Integer;
begin
  if MaintenanceUacCancelled then
    Result := MaintenanceUacCancelledExitCode
  else if PostInstallFailed then
    Result := 1
  else
    Result := 0;
end;

// Only recognized codes from the safe --json envelope can reach the log/UI.
function BootstrapFailure(const Output: TExecOutput): String;
var
  Known: TArrayOfString;
  I, J: Integer;
begin
  Result := 'service_start_failed';
  Known := ['config_invalid', 'config_recovery_required', 'config_missing', 'config_permissions_unsafe',
    'config_concurrent_change', 'workspace_unreadable', 'workspace_not_found', 'service_not_registered',
    'service_port_in_use', 'service_start_timeout', 'lan_firewall_blocked'];
  for I := 0 to GetArrayLength(Output.StdOut) - 1 do
    for J := 0 to GetArrayLength(Known) - 1 do
      if Pos('"code":"' + Known[J] + '"', Output.StdOut[I]) > 0 then begin
        Result := Known[J];
        Exit;
      end;
end;

procedure ApplyInstallerChoices;
var
  Requested, Enabled, CleanupFailed, NewRule: Boolean;
  Marker: Cardinal;
  Code: Integer;
  Parameters, Failure, SelectedRoot: String;
  Output: TExecOutput;
begin
  Requested := WizardIsTaskSelected('lanfirewall');
  Enabled := False;
  CleanupFailed := False;
  NewRule := False;
  MaintenanceUacCancelled := False;
  SelectedRoot := '';
  if not WizardSilent then
    if DirectoryConfirmed and WizardIsTaskSelected('confirmworkspace') and DirExists(WorkspacePage.Values[0]) then
      SelectedRoot := WorkspacePage.Values[0];
  RegisterScheduledTask;
  if Requested and ((SelectedRoot <> '') or RunMaintenance('workspace-confirmed')) and FirewallCheck('ValidateNetwork') then begin
    Enabled := FirewallCheck('Validate');
    if (not Enabled) and (not WizardSilent) then begin
      if RunMaintenance('enable-lan') then begin
        NewRule := True;
        RegWriteDWordValue(HKCU, ProductRegistryKey, FirewallMarkerName, 1);
        Enabled := FirewallCheck('Validate');
      end else if LastMaintenanceExitCode = MaintenanceUacCancelledExitCode then begin
        MaintenanceUacCancelled := True;
      end;
    end;
  end;
  if (not Requested) and RegQueryDWordValue(HKCU, ProductRegistryKey, FirewallMarkerName, Marker) and (Marker = 1) then begin
    if (not WizardSilent) and RunMaintenance('disable-lan') then
      RegDeleteValue(HKCU, ProductRegistryKey, FirewallMarkerName)
    else begin
      CleanupFailed := True;
      if LastMaintenanceExitCode = MaintenanceUacCancelledExitCode then
        MaintenanceUacCancelled := True;
    end;
  end;
  Parameters := 'up --installer-bootstrap --lan-enabled=';
  if Enabled then Parameters := Parameters + 'true' else Parameters := Parameters + 'false';
  Parameters := Parameters + ' --no-pair --json --wait 60s';
  if RequireExistingConfig then Parameters := Parameters + ' --require-existing';
  if SelectedRoot <> '' then
    Parameters := Parameters + ' --scan-root ' + Quote(AddBackslash(SelectedRoot) + '.');
  if not ExecAndCaptureOutput(AgentExecutable, Parameters, ExpandConstant('{sys}'), SW_HIDE,
    ewWaitUntilTerminated, Code, Output) then Code := -1;
  if (Code = 0) or FileExists(ExpandConstant('{userappdata}\mimi-remote\config.json')) then
    RegDeleteValue(HKCU, ProductRegistryKey, PendingBootstrapName);
  if Code <> 0 then begin
    if NewRule then begin
      if RunMaintenance('disable-lan') then
        RegDeleteValue(HKCU, ProductRegistryKey, FirewallMarkerName)
      else if LastMaintenanceExitCode = MaintenanceUacCancelledExitCode then
        MaintenanceUacCancelled := True;
    end;
    PostInstallFailed := True;
    Failure := BootstrapFailure(Output);
    if MaintenanceUacCancelled then
      Log('Installer bootstrap: ' + Failure + ' (lan_firewall_blocked: ERROR_CANCELLED)')
    else
      Log('Installer bootstrap: ' + Failure);
    if not WizardSilent then
      MsgBox('Setup could not verify the service or selected policy (' + Failure + '). Keep your configuration and check Mimi Remote diagnostics.', mbError, MB_OK);
    Exit;
  end;
  if (Requested and (not Enabled)) or CleanupFailed then begin
    PostInstallFailed := True;
    if MaintenanceUacCancelled then
      Log('lan_firewall_blocked: ERROR_CANCELLED; LAN disabled.')
    else
      Log('lan_firewall_blocked: LAN disabled; review the Private network and installer-owned rule.');
    if not WizardSilent then
      MsgBox('The core service is ready. LAN is off. Confirm the workspace and check the Private network and firewall, then retry from signed Setup.', mbInformation, MB_OK);
  end;
end;

; Built and signed before agentd. Its final Authenticode-covered file digest
; is linked into agentd. This independent Modify wizard installs no files and
; has no uninstaller. UI clients use "agentd installer-maintenance modify".
[Setup]
AppId=MimiRemoteMaintenance
AppName=Mimi Remote Maintenance
AppVersion={#MyAppVersion}
AppPublisher=Mimi Remote
PrivilegesRequired=lowest
CreateAppDir=no
Uninstallable=no
CreateUninstallRegKey=no
DisableProgramGroupPage=yes
UsePreviousTasks=no
CloseApplications=no
RestartApplications=no
AllowCancelDuringInstall=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=Mimi-Remote-Maintenance
SetupIconFile=mimi-remote.ico

[Tasks]
Name: "confirmworkspace"; Description: "Confirm a code folder for a new or pending workspace"; Flags: unchecked
Name: "lanfirewall"; Description: "Allow private LAN access (Private networks / LocalSubnet only)"; Flags: unchecked

[Files]
Source: "register-service.ps1"; DestDir: "{tmp}"; Flags: dontcopy
Source: "configure-firewall.ps1"; DestDir: "{tmp}"; Flags: dontcopy

[Code]
var
  SourceDirectory, MaintenanceMode: String;

function InstallDirectory: String;
begin
  Result := SourceDirectory;
end;

#include "installer-common.iss"
#ifdef SignedMaintenance
#include CommandInclude
#endif

function GetFinalPathNameByHandleW(FileHandle: THandle; Path: String; Size, Flags: Cardinal): Cardinal;
  external 'GetFinalPathNameByHandleW@kernel32.dll stdcall';

function SetEnvironmentVariableW(Name, Value: String): Boolean;
  external 'SetEnvironmentVariableW@kernel32.dll stdcall';

function MaintenanceDirectory: String;
var
  Image: TFileStream;
  Buffer: String;
  Count: Cardinal;
begin
  Result := '';
  Image := TFileStream.Create(ExpandConstant('{srcexe}'), fmOpenRead or fmShareDenyNone);
  try
    SetLength(Buffer, 32768);
    Count := GetFinalPathNameByHandleW(Image.Handle, Buffer, Length(Buffer), 0);
    if (Count = 0) or (Count >= Cardinal(Length(Buffer))) then Exit;
    SetLength(Buffer, Count);
    if Copy(Buffer, 1, 4) <> '\\?\' then Exit;
    Result := ExtractFileDir(Copy(Buffer, 5, Length(Buffer)));
  finally
    Image.Free;
  end;
end;

function InitializeSetup: Boolean;
begin
  Result := False;
#ifdef SignedMaintenance
  MaintenanceMode := ExpandConstant('{param:MIMIMODE|}');
  SourceDirectory := MaintenanceDirectory;
  if SourceDirectory = '' then Exit;
  if MaintenanceMode = 'modify' then
    Result := (not IsAdmin) and (not WizardSilent)
  else if (MaintenanceMode = 'enable-lan') or (MaintenanceMode = 'disable-lan') then
    // Bind the firewall target to our actual source directory after UAC.
    // The embedded command authenticates both fixed sibling images using
    // the release receipt, including over-the-shoulder administrator consent.
    Result := IsAdmin and WizardSilent and
      SetEnvironmentVariableW('MIMI_INNO_SOURCE_DIRECTORY', SourceDirectory);
#endif
end;

procedure InitializeWizard;
begin
  RequireExistingConfig := True;
  if MaintenanceMode = 'modify' then AddWorkspacePage;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
begin
  Result := '';
  if MaintenanceMode = 'modify' then begin
    // Stop the managed task before changing ingress. The calling agentd CLI
    // remains mapped while the wizard runs; Modify never replaces its binary.
    if not ExecConsoleHidden(InstallDirectory + '\agentd.exe', 'stop', Code) or (Code <> 0) then begin
      RegisterScheduledTask;
      if not ExecConsoleHidden(InstallDirectory + '\agentd.exe', 'stop', Code) or (Code <> 0) then
        Result := 'Unable to verify that the old service stopped. Check the current-user login task.';
    end;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
#ifdef SignedMaintenance
var
  Command: String;
  Code: Integer;
#endif
begin
  if CurStep <> ssPostInstall then Exit;
#ifdef SignedMaintenance
  if (MaintenanceMode = 'modify') and (not IsAdmin) then begin
    ApplyInstallerChoices;
    Exit;
  end;
  // Build embeds literal UTF-16 commands in this signed image. No script
  // from a user-writable path or caller-provided command runs under UAC.
  if not IsAdmin then RaiseException('Administrator approval is required.');
  if MaintenanceMode = 'enable-lan' then
    Command := EnableCommand
  else if MaintenanceMode = 'disable-lan' then
    Command := DisableCommand
  else
    RaiseException('Unknown maintenance operation.');
  if not ExecConsoleHidden(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + Command, Code) or (Code <> 0) then
    RaiseException('lan_firewall_blocked');
#endif
end;

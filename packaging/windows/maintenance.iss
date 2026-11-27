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
const
  VOLUME_NAME_DOS = 0;
  VOLUME_NAME_GUID = 1;
  AgentShareDenyWrite = $0020;
  FILE_ATTRIBUTE_DIRECTORY = $00000010;
  FILE_ATTRIBUTE_DEVICE = $00000040;
  FILE_ATTRIBUTE_REPARSE_POINT = $00000400;

var
  SourceDirectory, SourceVolumeDirectory, PinnedAgentPath, MaintenanceMode: String;
  PinnedAgentImage: TFileStream;

function InstallDirectory: String;
begin
  Result := SourceDirectory;
end;

function AgentExecutable: String;
begin
  Result := PinnedAgentPath;
end;

#include "installer-common.iss"
#ifdef SignedMaintenance
#include CommandInclude
#endif

function GetFinalPathNameByHandleW(FileHandle: THandle; Path: String; Size, Flags: Cardinal): Cardinal;
  external 'GetFinalPathNameByHandleW@kernel32.dll stdcall';

function GetFileAttributesW(FileName: String): Cardinal;
  external 'GetFileAttributesW@kernel32.dll stdcall';

function SetEnvironmentVariableW(Name, Value: String): Boolean;
  external 'SetEnvironmentVariableW@kernel32.dll stdcall';

function FinalPathByHandle(FileHandle: THandle; Flags: Cardinal): String;
var
  Buffer: String;
  Count: Cardinal;
begin
  Result := '';
  SetLength(Buffer, 32768);
  Count := GetFinalPathNameByHandleW(FileHandle, Buffer, Length(Buffer), Flags);
  if (Count = 0) or (Count >= Cardinal(Length(Buffer))) then Exit;
  SetLength(Buffer, Count);
  Result := Buffer;
end;

function ParentDirectoryPath(const FullPath: String): String;
var
  I: Integer;
begin
  Result := '';
  for I := Length(FullPath) downto 1 do
    if FullPath[I] = '\' then begin
      Result := Copy(FullPath, 1, I - 1);
      Exit;
    end;
end;

function MaintenanceDirectory: String;
var
  Image: TFileStream;
  DosPath, GuidPath, VolumeDir: String;
begin
  Result := '';
  SourceVolumeDirectory := '';
  try
    Image := TFileStream.Create(ExpandConstant('{srcexe}'), fmOpenRead or fmShareDenyNone);
  except
    Exit;
  end;
  try
    DosPath := FinalPathByHandle(Image.Handle, VOLUME_NAME_DOS);
    GuidPath := FinalPathByHandle(Image.Handle, VOLUME_NAME_GUID);
    if (Copy(DosPath, 1, 4) <> '\\?\') or
       (CompareText(Copy(GuidPath, 1, 11), '\\?\Volume{') <> 0) then Exit;
    VolumeDir := ParentDirectoryPath(GuidPath);
    if CompareText(Copy(VolumeDir, 1, 11), '\\?\Volume{') <> 0 then Exit;
    SourceVolumeDirectory := VolumeDir;
    Result := ExtractFileDir(Copy(DosPath, 5, Length(DosPath)));
  finally
    Image.Free;
  end;
end;

// Pin the sibling agentd.exe with FILE_SHARE_READ (fmShareDenyWrite) on the
// same volume-GUID path and execute all child broker invocations via that
// handle's volume-GUID final path instead of re-resolving a drive letter.
function PinSiblingAgentImage(const VolumeDir: String; var AgentPath: String): Boolean;
var
  Candidate, FinalGuidPath: String;
  Attrs: Cardinal;
begin
  Result := False;
  AgentPath := '';
  if CompareText(Copy(VolumeDir, 1, 11), '\\?\Volume{') <> 0 then Exit;
  Candidate := VolumeDir + '\agentd.exe';
  Attrs := GetFileAttributesW(Candidate);
  if (Attrs = Cardinal($FFFFFFFF)) or
     ((Attrs and (FILE_ATTRIBUTE_REPARSE_POINT or FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_DEVICE)) <> 0) then Exit;
  try
    PinnedAgentImage := TFileStream.Create(Candidate, fmOpenRead or AgentShareDenyWrite);
  except
    PinnedAgentImage := nil;
    Exit;
  end;
  FinalGuidPath := FinalPathByHandle(PinnedAgentImage.Handle, VOLUME_NAME_GUID);
  if (FinalGuidPath = '') or (CompareText(FinalGuidPath, Candidate) <> 0) then begin
    PinnedAgentImage.Free;
    PinnedAgentImage := nil;
    Exit;
  end;
  AgentPath := FinalGuidPath;
  Result := True;
end;

procedure DeinitializeSetup;
begin
  if PinnedAgentImage <> nil then begin
    PinnedAgentImage.Free;
    PinnedAgentImage := nil;
  end;
end;

function InitializeSetup: Boolean;
begin
  Result := False;
#ifdef SignedMaintenance
  MaintenanceMode := ExpandConstant('{param:MIMIMODE|}');
  SourceDirectory := MaintenanceDirectory;
  if (SourceDirectory = '') or (SourceVolumeDirectory = '') then Exit;
  if MaintenanceMode = 'modify' then
    Result := (not IsAdmin) and (not WizardSilent) and
      PinSiblingAgentImage(SourceVolumeDirectory, PinnedAgentPath)
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
    if not ExecConsoleHidden(AgentExecutable, 'stop', Code) or (Code <> 0) then begin
      RegisterScheduledTask;
      if not ExecConsoleHidden(AgentExecutable, 'stop', Code) or (Code <> 0) then
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
    '-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + Command, Code) or (Code <> 0) then begin
    PostInstallFailed := True;
    Log('lan_firewall_blocked');
  end;
#endif
end;

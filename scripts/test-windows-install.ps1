[CmdletBinding()]
param([string]$RepositoryRoot)
$ErrorActionPreference = 'Stop'
$RepositoryRoot = if ($RepositoryRoot) { $RepositoryRoot } else { Join-Path $PSScriptRoot '..' }
$root = (Resolve-Path $RepositoryRoot).Path
$iss = Join-Path $root 'packaging\windows\mimi-remote.iss'
$register = Join-Path $root 'packaging\windows\register-service.ps1'
$firewall = Join-Path $root 'packaging\windows\configure-firewall.ps1'
$signing = Join-Path $root 'packaging\windows\sign-authenticode.ps1'
$icon = Join-Path $root 'packaging\windows\mimi-remote.ico'
$build = Join-Path $root 'scripts\build-windows-installer.ps1'
$check = Join-Path $root 'scripts\check-windows-installer.ps1'
$releaseWorkflow = Join-Path $root '.github\workflows\release.yml'
$windowsDocs = @(
    (Join-Path $root 'README.md'),
    (Join-Path $root 'README.zh-CN.md'),
    (Join-Path $root 'docs\install-upgrade-rollback.md')
)
foreach ($path in @($iss, $register, $firewall, $signing, $icon, $build, $check, $releaseWorkflow) + $windowsDocs) { if (-not (Test-Path -LiteralPath $path)) { throw "Missing required packaging file: $path" } }
$common = Get-Content -LiteralPath (Join-Path $root 'packaging\windows\installer-common.iss') -Raw
$maintenance = Get-Content -LiteralPath (Join-Path $root 'packaging\windows\maintenance.iss') -Raw
$source = (Get-Content -LiteralPath $iss -Raw).Replace('#include "installer-common.iss"', $common)
foreach ($expected in @('{localappdata}\Programs\Mimi Remote', 'agentd.exe', 'mimi-claude-adapter.exe', 'alleycat-claude-bridge.exe', 'mimi-remote-tray.exe', 'mimi-tailcat-experiment.exe', 'THIRD_PARTY_NOTICES.md', 'StopTailcatHelper', 'fmShareExclusive', 'mimi-remote.ico', 'SetupIconFile=mimi-remote.ico', 'UninstallDisplayIcon={app}\mimi-remote.ico', 'IconFilename: "{app}\mimi-remote.ico"', '{userstartup}\Mimi Remote', 'Parameters: "--show"', 'register-service.ps1', 'configure-firewall.ps1', 'PrivilegesRequired=lowest', 'Flags: unchecked', 'GetCustomSetupExitCode', 'PrivateLanFirewallRule', 'UsePreviousTasks=no', 'StopTrayApp', 'Mimi-Remote-Maintenance.exe', 'AddWorkspacePage', 'OutputBaseFilename={#MyOutputBaseFilename}', 'SignTool={#MySignTool}', 'SignedUninstaller=yes', 'SignedUninstaller=no')) {
    if (-not $source.Contains($expected)) { throw "Installer source is missing required policy: $expected" }
}
if ($source.Contains('no longer supports Windows as the agentd host') -or $source.Contains('function InitializeSetup(): Boolean')) {
    throw 'Windows installer must not reject the supported local host path before installation.'
}
# #975 回归门禁：安装链路不得再出现可见控制台入口。
foreach ($forbidden in @('SW_SHOW', '{cmd}')) {
    if ($source.Contains($forbidden)) { throw "Installer source must not contain a console entry point: $forbidden" }
}
if ($source -match '\bExec\s*\(' -or -not $source.Contains('ExecAndCaptureOutput(')) {
    throw 'Installer must run console commands through the no-console capture helper.'
}
if (-not $source.Contains('mimi-agent-host.exe')) { throw 'Installer must ship the no-window agent host.' }
if (-not $source.Contains('-HostPath ')) { throw 'Installer must register the scheduled task against the agent host.' }
$prepareSource = $source.Substring($source.IndexOf('function PrepareToInstall'), $source.IndexOf('procedure CurStepChanged') - $source.IndexOf('function PrepareToInstall'))
if ($prepareSource.IndexOf('StopManagedService;') -gt $prepareSource.IndexOf('StopTrayApp;')) {
    throw 'Upgrade must stop the managed service gracefully before terminating the shared tray image.'
}
if ($prepareSource.IndexOf('StopTailcatHelper;') -lt $prepareSource.IndexOf('StopManagedService;')) {
    throw 'Upgrade must let agentd stop the Tailcat helper before checking or force-stopping its image.'
}
foreach ($procedure in @('StopManagedService', 'StopTrayApp')) {
    $start = $source.IndexOf("procedure $procedure;")
    $body = $source.Substring($start, $source.IndexOf('RaiseException', $start) - $start)
    if (-not $body.Contains('ExecutableIsReleased(') -or $body.Contains('RenameFile(')) {
        throw "$procedure must wait for an exclusive open of the image; a rename succeeds while the process still runs."
    }
}
if ($source.IndexOf('function ExecutableIsReleased') -gt $source.IndexOf('procedure StopManagedService;')) {
    throw 'ExecutableIsReleased must be declared before the stop procedures that call it.'
}
$uninstallSource = $source.Substring($source.IndexOf('procedure CurUninstallStepChanged'))
if ($uninstallSource.IndexOf('StopManagedService;') -gt $uninstallSource.IndexOf('StopTrayApp;')) {
    throw 'Uninstall must stop the managed service gracefully before terminating the shared tray image.'
}
if ($uninstallSource.IndexOf('StopTailcatHelper;') -lt $uninstallSource.IndexOf('StopManagedService;')) {
    throw 'Uninstall must let agentd stop the Tailcat helper before checking or force-stopping its image.'
}
$choices = $common.Substring($common.IndexOf('procedure ApplyInstallerChoices;'))
foreach ($expected in @("FirewallCheck('ValidateNetwork')", "FirewallCheck('Validate')", "RunMaintenance('enable-lan')",
    "RunMaintenance('disable-lan')", 'RegisterScheduledTask;', 'up --installer-bootstrap --lan-enabled=', ' --no-pair --json --wait 60s',
    "' --require-existing'", 'not WizardSilent', 'DirectoryConfirmed', "WizardIsTaskSelected('confirmworkspace')")) {
    if (-not $choices.Contains($expected)) { throw "Installer choice is missing: $expected" }
}
$workspaceGate = "if Requested and ((SelectedRoot <> '') or RunMaintenance('workspace-confirmed')) and FirewallCheck('ValidateNetwork') then begin"
if (-not $choices.Contains($workspaceGate) -or $choices.IndexOf('RegisterScheduledTask;') -gt $choices.IndexOf($workspaceGate) -or
    $choices.IndexOf($workspaceGate) -gt $choices.IndexOf("RunMaintenance('enable-lan')") -or
    $choices.IndexOf("RunMaintenance('enable-lan')") -gt $choices.IndexOf('up --installer-bootstrap') -or
    ([regex]::Matches($choices, 'up --installer-bootstrap')).Count -ne 1 -or
    $source -match "'(restart|network) --") { throw 'Verify the task and workspace before optional LAN authorization and the single bootstrap.' }
if (-not $prepareSource.Contains('CompareText(PendingDirectory, InstallDirectory) = 0') -or
    -not $prepareSource.Contains('RegWriteStringValue(HKCU, ProductRegistryKey, PendingBootstrapName, InstallDirectory)') -or
    -not $choices.Contains('RegDeleteValue(HKCU, ProductRegistryKey, PendingBootstrapName)')) {
    throw 'A failed fresh task registration must leave the same installation eligible for first bootstrap.'
}
foreach ($forbidden in @('ShellExec(', 'UninstallString', 'ModifyPath')) {
    if (($source + $maintenance).Contains($forbidden)) { throw "Unsafe maintenance path: $forbidden" }
}
foreach ($expected in @('Uninstallable=no', 'PrivilegesRequired=lowest', '#ifdef SignedMaintenance', 'not IsAdmin',
    'IsAdmin and WizardSilent', 'SetEnvironmentVariableW', 'MaintenanceDirectory', '-EncodedCommand', 'PostInstallFailed := True')) {
    if (-not $maintenance.Contains($expected)) { throw "Maintenance boundary missing: $expected" }
}
$registerSource = Get-Content -LiteralPath $register -Raw
foreach ($expected in @('New-ScheduledTaskTrigger -AtLogOn', 'New-ScheduledTaskPrincipal', '-LogonType Interactive', '-RunLevel Limited', 'New-ScheduledTaskAction -Execute $HostPath', '--log-file `"$LogPath`"', 'ExecutionTimeLimit ([TimeSpan]::Zero)', 'Stop-ScheduledTask -TaskName $TaskName', "State -in @('Running', 'Queued')", 'Scheduled task did not stop within 10 seconds', '$registeredSid -ne $currentSid', '$actions.Count -ne 1', '$actions[0].Arguments -cne $action.Arguments', '$actions[0].WorkingDirectory', '$registered.Principal.LogonType')) {
    if (-not $registerSource.Contains($expected)) { throw "Task registration script is missing required policy: $expected" }
}
$registerBytes = [IO.File]::ReadAllBytes($register)
$registerHasUtf8Bom = $registerBytes.Length -ge 3 -and $registerBytes[0] -eq 0xEF -and $registerBytes[1] -eq 0xBB -and $registerBytes[2] -eq 0xBF
if (-not $registerHasUtf8Bom -and $registerBytes.Where({ $_ -gt 0x7F }, 'First').Count -gt 0) {
    throw 'Windows PowerShell 5.1 scripts with non-ASCII text must include a UTF-8 BOM.'
}
if ($env:OS -eq 'Windows_NT') {
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $previousRegisterScript = $env:MIMI_REGISTER_SCRIPT
    $previousFirewallScript = $env:MIMI_FIREWALL_SCRIPT
    $env:MIMI_REGISTER_SCRIPT = $register
    $env:MIMI_FIREWALL_SCRIPT = $firewall
    $parserProbe = @'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($env:MIMI_REGISTER_SCRIPT, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
    $errors | ForEach-Object { [Console]::Error.WriteLine($_.Message) }
    exit 1
}
$assignment = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$action'
}, $true)
if (-not $assignment -or
    -not $assignment.Right.Extent.Text.Contains('$HostPath') -or
    -not $assignment.Right.Extent.Text.Contains('--log-file')) {
    [Console]::Error.WriteLine('Windows PowerShell 5.1 did not parse the no-window host action.')
    exit 1
}
[void][System.Management.Automation.Language.Parser]::ParseFile($env:MIMI_FIREWALL_SCRIPT, [ref]$tokens, [ref]$errors)
if ($errors.Count) {
    $errors | ForEach-Object { [Console]::Error.WriteLine($_.Message) }
    exit 1
}
'@
    $encodedProbe = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($parserProbe))
    try {
        & $windowsPowerShell -NoLogo -NoProfile -NonInteractive -EncodedCommand $encodedProbe
        if ($LASTEXITCODE -ne 0) { throw 'Windows PowerShell 5.1 compatibility probe failed.' }
    } finally {
        $env:MIMI_FIREWALL_SCRIPT = $previousFirewallScript
        if ($null -eq $previousRegisterScript) {
            Remove-Item Env:MIMI_REGISTER_SCRIPT -ErrorAction SilentlyContinue
        } else {
            $env:MIMI_REGISTER_SCRIPT = $previousRegisterScript
        }
    }
}
$firewallSource = Get-Content -LiteralPath $firewall -Raw
foreach ($expected in @("ValidateSet('Enable', 'Disable', 'Validate', 'ValidateNetwork')", 'Get-NetConnectionProfile', 'Get-ProgramAllows', 'ActiveStore', 'PersistentStore', 'Where-Object Name -eq $ownedName', '@($address.RemoteAddress).Count -eq 1', '-Profile Private', '-RemoteAddress LocalSubnet', '-Program $AgentPath', 'Get-NetFirewallApplicationFilter', 'Get-NetFirewallAddressFilter')) {
    if (-not $firewallSource.Contains($expected)) { throw "Firewall script is missing required policy: $expected" }
}
if ($firewallSource.Contains('Remove-Unmanaged') -or $firewallSource -match 'Set-Net(Firewall|Connection)Profile' -or
    ([regex]::Matches($firewallSource, 'Remove-NetFirewallRule')).Count -ne 1 -or
    -not $firewallSource.Contains('$rule | Remove-NetFirewallRule')) { throw 'Only remove the exact owned firewall rule.' }
if (-not $firewallSource.Contains('if ($created) { Remove-OwnedFirewallRule $created }')) {
    throw 'A new installer-owned rule must be rolled back if its effective policy cannot be verified.'
}
if ($source.Contains('[InstallDelete]')) { throw 'Installer must preserve the blanket InstallDelete prohibition.' }
if (-not $source.Contains("DeleteFile(ExpandConstant('{group}\Mimi Remote Logs.lnk'))")) { throw 'Upgrade must remove the legacy log shortcut explicitly.' }
foreach ($script in @($register, $firewall, $signing, $build, $check)) { [void][scriptblock]::Create((Get-Content -LiteralPath $script -Raw)) }
$buildSource = Get-Content -LiteralPath $build -Raw
foreach ($expected in @('signtool verify /pa $maintenance', 'main.maintenanceImageSHA256=$pin', 'maintenance-identity.p7m',
    'mimi.windows.maintenance/v1', 'Where-Object Name -ne $maintenanceName', 'SignedCms', 'broker_sha256')) {
    if (-not $buildSource.Contains($expected)) { throw "Missing signed maintenance identity binding: $expected" }
}
if (-not $buildSource.Contains('target-feature=+crt-static')) { throw 'Windows release bridge must use a static Rust CRT.' }
if (-not $buildSource.Contains('--target=bun-windows-x64-baseline')) { throw 'Windows release must build the Claude adapter with the baseline Bun runtime.' }
if (-not $buildSource.Contains('The signed Claude adapter failed its version probe.')) { throw 'Signed release builds must re-run the Claude adapter after Authenticode signing.' }
if (-not $buildSource.Contains('/DMySignTool=mimi-authenticode')) { throw 'Release builds must register the Inno Setup Authenticode signing tool.' }
if (-not $buildSource.Contains('[switch]$AllowUnsignedRelease')) { throw 'Unsigned release builds must require an explicit switch.' }
if (-not $buildSource.Contains("'unsigned-release'")) { throw 'Unsigned release builds must record their signing mode in metadata.' }
if (-not $buildSource.Contains('Mimi-Remote-Setup-$Version-unsigned')) { throw 'Unsigned release filenames must identify that they are unsigned.' }
if (-not $buildSource.Contains('-X main.releaseVersion=$Version')) { throw 'Windows tray builds must embed the installer and GitHub Release version.' }
foreach ($expected in @('experiments\tailcat', "`$env:GOTOOLCHAIN = 'auto'", 'tailcat_version = $tailcatVersion', 'The signed Tailcat helper failed its version probe.', 'THIRD_PARTY_NOTICES.md')) {
    if (-not $buildSource.Contains($expected)) { throw "Windows installer build is missing the bundled Tailcat helper policy: $expected" }
}
$checkSource = Get-Content -LiteralPath $check -Raw
if (-not $checkSource.Contains("'unsigned-release'")) { throw 'Installer validation must recognize unsigned release metadata.' }
foreach ($expected in @('mimi-tailcat-experiment.exe', '$metadata.tailcat_version -ne $metadata.version', 'THIRD_PARTY_NOTICES.md', '$ExpectedVersion')) {
    if (-not $checkSource.Contains($expected)) { throw "Installer validation is missing the bundled Tailcat helper policy: $expected" }
}
$releaseSource = Get-Content -LiteralPath $releaseWorkflow -Raw
$currentRepositoryGate = "github.repository == 'gaixianggeng/mimi-remote'"
if (($releaseSource.Split($currentRepositoryGate).Count - 1) -lt 4) { throw 'All release jobs, including Windows compatibility verification, must target the source repository.' }
if (-not $releaseSource.Contains('-AllowUnsignedRelease')) { throw 'Release workflow must explicitly opt into unsigned Windows packaging when credentials are absent.' }
if (-not $releaseSource.Contains('must either both be configured or both be absent')) { throw 'Partial Windows signing credentials must fail the release.' }
if (-not $releaseSource.Contains('-RequireSignature')) { throw 'Release workflow must still enforce Authenticode when signing credentials exist.' }
if (($releaseSource.Split('-ExpectedVersion $env:RELEASE_TAG').Count - 1) -lt 2) { throw 'Release workflow must verify the installer and its Tailcat helper against the release tag in both signing modes.' }
if (-not $releaseSource.Contains('./scripts/publish-windows-client.ps1')) { throw 'Release workflow must also publish the version-matched WinUI client.' }
$publishClient = Get-Content -LiteralPath (Join-Path $root 'scripts\publish-windows-client.ps1') -Raw
foreach ($expected in @('-p:MimiReleasePublisherSha256=$publisher', 'signtool verify /pa $clientExe', 'Mimi-Remote-Client-$releaseVersion-win-x64.zip')) {
    if (-not $publishClient.Contains($expected)) { throw "WinUI client release publishing is missing required policy: $expected" }
}
$winUiProject = Get-Content -LiteralPath (Join-Path $root 'windows\src\MimiRemote.App\MimiRemote.App.csproj') -Raw
if (-not $winUiProject.Contains('AssemblyMetadata Include="MimiReleasePublisherSha256"')) {
    throw 'WinUI project must embed MimiReleasePublisherSha256 when supplied by release builds.'
}
$winUiNative = Get-Content -LiteralPath (Join-Path $root 'windows\src\MimiRemote.App\WindowsMaintenanceNative.cs') -Raw
if ($winUiNative.Contains('TryExtractVerifiedSelfPublisherSha256')) {
    throw 'WinUI maintenance verification must not fall back to reading a self-signer from disk.'
}
if (-not $common.Contains('MaintenanceUacCancelledExitCode = 1223')) {
    throw 'Installer common script must propagate distinct UAC cancellation exit code 1223.'
}
foreach ($path in $windowsDocs) {
    $docSource = Get-Content -LiteralPath $path -Raw
    if (-not $docSource.Contains('Windows')) {
        throw "Windows documentation must describe the supported agentd host path: $path"
    }
    if ($docSource -notmatch '(loopback|127\.0\.0\.1)') {
        throw "Windows documentation must describe the loopback App Server transport: $path"
    }
    if ($docSource -match '(installer publishing is paused|安装器发布暂停)') {
        throw "Windows documentation must not describe installer publishing as paused: $path"
    }
}
# Exercise the elevated command's identity check without executing any image
# or touching NetSecurity. A locally generated key stands in for the release key.
$ast = [scriptblock]::Create($firewallSource).Ast
$identityCheck = $ast.Find({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Assert-SignedInstall'
}, $true)
. ([scriptblock]::Create($identityCheck.Extent.Text))
$receiptDir = Join-Path ([IO.Path]::GetTempPath()) ("mimi-receipt-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $receiptDir | Out-Null
if ($IsMacOS) { $receiptDir = (& /bin/sh -c 'cd -P "$1" && pwd -P' sh $receiptDir).Trim() }
$rsa = [Security.Cryptography.RSA]::Create(2048)
$testCert = $null
$oldPublisher = $env:MIMI_SIGNED_PUBLISHER
$oldVersion = $env:MIMI_SIGNED_VERSION
try {
    $req = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=MimiTest', $rsa,
        [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $testCert = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddHours(-1), [DateTimeOffset]::UtcNow.AddHours(1))
    $env:MIMI_SIGNED_PUBLISHER = $testCert.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256)
    $env:MIMI_SIGNED_VERSION = '0.0.0'
    $brokerPath = Join-Path $receiptDir 'agentd.exe'
    $imagePath = Join-Path $receiptDir 'Mimi-Remote-Maintenance.exe'
    Set-Content $brokerPath 'broker fixture'
    Set-Content $imagePath 'maintenance fixture'
    $record = [ordered]@{
        schema = 'mimi.windows.maintenance/v1'; version = '0.0.0'
        broker = 'agentd.exe'; broker_sha256 = (Get-FileHash $brokerPath).Hash
        maintenance = 'Mimi-Remote-Maintenance.exe'; maintenance_sha256 = (Get-FileHash $imagePath).Hash
    } | ConvertTo-Json -Compress
    $cms = [System.Security.Cryptography.Pkcs.SignedCms]::new(
        [System.Security.Cryptography.Pkcs.ContentInfo]::new([Text.Encoding]::UTF8.GetBytes($record)))
    $cms.ComputeSignature([System.Security.Cryptography.Pkcs.CmsSigner]::new($testCert), $true)
    [IO.File]::WriteAllBytes((Join-Path $receiptDir 'maintenance-identity.p7m'), $cms.Encode())
    foreach ($case in @('valid', 'publisher', 'version', 'substituted-image')) {
        $pins = [Collections.Generic.List[IO.FileStream]]::new()
        $env:MIMI_SIGNED_PUBLISHER = if ($case -eq 'publisher') { 'different' } else { $testCert.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256) }
        $env:MIMI_SIGNED_VERSION = if ($case -eq 'version') { '0.0.1' } else { '0.0.0' }
        if ($case -eq 'substituted-image') { Set-Content $imagePath 'uninstaller fixture' }
        $accepted = $false
        try { Assert-SignedInstall $receiptDir $pins; $accepted = $true }
        catch { if ($case -eq 'valid') { throw } }
        finally { foreach ($pin in $pins) { $pin.Dispose() } }
        if ($accepted -ne ($case -eq 'valid')) { throw "Unexpected maintenance receipt result: $case" }
    }
} finally {
    $env:MIMI_SIGNED_PUBLISHER = $oldPublisher
    $env:MIMI_SIGNED_VERSION = $oldVersion
    if ($testCert) { $testCert.Dispose() }
    $rsa.Dispose()
    Remove-Item -LiteralPath $receiptDir -Recurse -Force
}

# Compile both Inno entry points on the native Windows runner. The fixture
# contains no runnable payload and no setup/uninstall program is executed.
if ($env:OS -eq 'Windows_NT') {
    $compiler = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
    if (-not $compiler) { $compiler = Join-Path "${env:ProgramFiles(x86)}" 'Inno Setup 6\ISCC.exe' }
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ("mimi-inno-test-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $fixture | Out-Null
    try {
        $commandInclude = Join-Path $fixture 'commands.iss'
        @("function EnableCommand: String; begin Result := ''; end;",
          "function DisableCommand: String; begin Result := ''; end;") | Set-Content -Encoding ascii $commandInclude
        & $compiler '/Q' '/DMyAppVersion=0.0.0' "/DOutputDir=$fixture" '/DSignedMaintenance=1' "/DCommandInclude=$commandInclude" (Join-Path $root 'packaging\windows\maintenance.iss')
        if ($LASTEXITCODE -ne 0) { throw 'Maintenance Inno compilation failed.' }
        foreach ($name in @('agentd.exe', 'mimi-agent-host.exe', 'mimi-claude-adapter.exe', 'alleycat-claude-bridge.exe',
                'mimi-remote-tray.exe', 'mimi-tailcat-experiment.exe', 'THIRD_PARTY_NOTICES.md')) {
            Set-Content -LiteralPath (Join-Path $fixture $name) -Value 'fixture'
        }
        Copy-Item -LiteralPath $icon -Destination (Join-Path $fixture 'mimi-remote.ico')
        & $compiler '/Q' '/DMyAppVersion=0.0.0' "/DSourceDir=$fixture" "/DOutputDir=$fixture" '/DMyOutputBaseFilename=fixture' $iss
        if ($LASTEXITCODE -ne 0) { throw 'Main Inno compilation failed.' }
    } finally { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
# Static-only acceptance: do not invoke Setup.exe or schtasks.exe, so no real user task or firewall rule is created.
Write-Host 'Windows installer static/dry-run acceptance passed; no scheduled task or firewall rule was created.'

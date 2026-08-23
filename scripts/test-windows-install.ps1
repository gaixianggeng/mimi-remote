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
$source = Get-Content -LiteralPath $iss -Raw
foreach ($expected in @('{localappdata}\Programs\Mimi Remote', 'agentd.exe', 'alleycat-claude-bridge.exe', 'mimi-remote-tray.exe', 'mimi-remote.ico', 'SetupIconFile=mimi-remote.ico', 'UninstallDisplayIcon={app}\mimi-remote.ico', 'IconFilename: "{app}\mimi-remote.ico"', '{userstartup}\Mimi Remote', 'Parameters: "--show"', 'register-service.ps1', 'configure-firewall.ps1', 'PrivilegesRequired=lowest', 'Flags: unchecked', 'GetCustomSetupExitCode', 'PrivateLanFirewallRule', 'PrivateLanNetworkProfileIsReady', 'StopTrayApp', 'ConfigureLANAccess(False)', 'ConfigureLANAccess(True)', 'OutputBaseFilename={#MyOutputBaseFilename}', 'SignTool={#MySignTool}', 'SignedUninstaller=yes', 'SignedUninstaller=no')) {
    if (-not $source.Contains($expected)) { throw "Installer source is missing required policy: $expected" }
}
$postInstallSource = $source.Substring($source.IndexOf('procedure CurStepChanged'))
if ($postInstallSource.IndexOf('PrivateLanNetworkProfileIsReady') -gt $postInstallSource.IndexOf('RegisterScheduledTask;')) {
    throw 'Private-network validation must run before the upgraded scheduled task is registered or started.'
}
if ($postInstallSource.IndexOf('ConfigurePrivateLanFirewallRule(True)') -gt $postInstallSource.IndexOf('RegisterScheduledTask;')) {
    throw 'Unsafe inbound rules must be repaired before the upgraded scheduled task is registered or started.'
}
$registerSource = Get-Content -LiteralPath $register -Raw
foreach ($expected in @('New-ScheduledTaskTrigger -AtLogOn', 'New-ScheduledTaskPrincipal', '-LogonType Interactive', '-RunLevel Limited', 'serve --managed-service --log-file', 'ExecutionTimeLimit ([TimeSpan]::Zero)', 'Stop-ScheduledTask -TaskName $TaskName', "State -in @('Running', 'Queued')", 'Scheduled task did not stop within 10 seconds')) {
    if (-not $registerSource.Contains($expected)) { throw "Task registration script is missing required policy: $expected" }
}
foreach ($expected in @('up --no-pair --wait 30s', 'restart --no-pair --wait 30s')) {
    if (-not $source.Contains($expected)) { throw "Installer source is missing the extended cold-start readiness window: $expected" }
}
$firewallSource = Get-Content -LiteralPath $firewall -Raw
foreach ($expected in @("ValidateSet('Enable', 'Disable', 'Validate', 'ValidateNetwork')", 'Get-NetConnectionProfile', 'Get-UnmanagedInboundAllowRules', 'Remove-UnmanagedInboundAllowRules', '-Profile Private', '-RemoteAddress LocalSubnet', '-Program $AgentPath', 'Get-NetFirewallApplicationFilter', 'Get-NetFirewallAddressFilter')) {
    if (-not $firewallSource.Contains($expected)) { throw "Firewall script is missing required policy: $expected" }
}
if ($source -match '(?m)^\[InstallDelete\]$') { throw 'Installer must not delete user configuration/log directories on normal uninstall.' }
foreach ($script in @($register, $firewall, $signing, $build, $check)) { [void][scriptblock]::Create((Get-Content -LiteralPath $script -Raw)) }
$buildSource = Get-Content -LiteralPath $build -Raw
if (-not $buildSource.Contains('target-feature=+crt-static')) { throw 'Windows release bridge must use a static Rust CRT.' }
if (-not $buildSource.Contains('/DMySignTool=mimi-authenticode')) { throw 'Release builds must register the Inno Setup Authenticode signing tool.' }
if (-not $buildSource.Contains('[switch]$AllowUnsignedRelease')) { throw 'Unsigned release builds must require an explicit switch.' }
if (-not $buildSource.Contains("'unsigned-release'")) { throw 'Unsigned release builds must record their signing mode in metadata.' }
if (-not $buildSource.Contains('Mimi-Remote-Setup-$Version-unsigned')) { throw 'Unsigned release filenames must identify that they are unsigned.' }
$checkSource = Get-Content -LiteralPath $check -Raw
if (-not $checkSource.Contains("'unsigned-release'")) { throw 'Installer validation must recognize unsigned release metadata.' }
$releaseSource = Get-Content -LiteralPath $releaseWorkflow -Raw
$currentRepositoryGate = "github.repository == 'gaixianggeng/mimi-remote'"
if (($releaseSource.Split($currentRepositoryGate).Count - 1) -lt 4) { throw 'All release jobs, including Windows verify/publish, must target the source repository.' }
if (-not $releaseSource.Contains('-AllowUnsignedRelease')) { throw 'Release workflow must explicitly opt into unsigned Windows packaging when credentials are absent.' }
if (-not $releaseSource.Contains('must either both be configured or both be absent')) { throw 'Partial Windows signing credentials must fail the release.' }
if (-not $releaseSource.Contains('-RequireSignature')) { throw 'Release workflow must still enforce Authenticode when signing credentials exist.' }
$currentReleaseURL = 'https://github.com/gaixianggeng/mimi-remote/releases/latest'
foreach ($path in $windowsDocs) {
    $docSource = Get-Content -LiteralPath $path -Raw
    if (-not $docSource.Contains($currentReleaseURL)) { throw "Windows download documentation must target the source repository: $path" }
    if (-not $docSource.Contains('unsigned-release')) { throw "Windows download documentation must explain unsigned release artifacts: $path" }
}
# Static-only acceptance: do not invoke Setup.exe or schtasks.exe, so no real user task or firewall rule is created.
Write-Host 'Windows installer static/dry-run acceptance passed; no scheduled task or firewall rule was created.'

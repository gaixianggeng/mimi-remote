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
foreach ($expected in @('{localappdata}\Programs\Mimi Remote', 'agentd.exe', 'alleycat-claude-bridge.exe', 'mimi-remote-tray.exe', 'mimi-remote.ico', 'SetupIconFile=mimi-remote.ico', 'UninstallDisplayIcon={app}\mimi-remote.ico', 'IconFilename: "{app}\mimi-remote.ico"', '{userstartup}\Mimi Remote', 'Parameters: "--show"', 'register-service.ps1', 'configure-firewall.ps1', 'PrivilegesRequired=lowest', 'Flags: unchecked', 'GetCustomSetupExitCode', 'PrivateLanFirewallRule', 'PrivateLanNetworkProfileIsReady', 'StopTrayApp', 'ConfigureLANAccess(False)', 'ConfigureLANAccess(True)', 'OutputBaseFilename={#MyOutputBaseFilename}', 'SignTool={#MySignTool}', 'SignedUninstaller=yes', 'SignedUninstaller=no', 'function InitializeSetup(): Boolean', 'no longer supports Windows as the agentd host', 'Result := False;')) {
    if (-not $source.Contains($expected)) { throw "Installer source is missing required policy: $expected" }
}
$initializeSource = $source.Substring($source.IndexOf('function InitializeSetup'), $source.IndexOf('procedure RemoveScheduledTask') - $source.IndexOf('function InitializeSetup'))
if ($initializeSource.IndexOf('Result := False;') -lt 0) {
    throw 'Windows host compatibility gate must reject Setup before any install mutation.'
}
$prepareSource = $source.Substring($source.IndexOf('function PrepareToInstall'), $source.IndexOf('procedure CurStepChanged') - $source.IndexOf('function PrepareToInstall'))
if ($prepareSource.IndexOf('StopManagedService;') -gt $prepareSource.IndexOf('StopTrayApp;')) {
    throw 'Upgrade must stop the managed service gracefully before terminating the shared tray image.'
}
$uninstallSource = $source.Substring($source.IndexOf('procedure CurUninstallStepChanged'))
if ($uninstallSource.IndexOf('StopManagedService;') -gt $uninstallSource.IndexOf('StopTrayApp;')) {
    throw 'Uninstall must stop the managed service gracefully before terminating the shared tray image.'
}
$postInstallSource = $source.Substring($source.IndexOf('procedure CurStepChanged'))
if ($postInstallSource.IndexOf('PrivateLanNetworkProfileIsReady') -gt $postInstallSource.IndexOf('RegisterScheduledTask;')) {
    throw 'Private-network validation must run before the upgraded scheduled task is registered or started.'
}
if ($postInstallSource.IndexOf('ConfigurePrivateLanFirewallRule(True)') -gt $postInstallSource.IndexOf('RegisterScheduledTask;')) {
    throw 'Unsafe inbound rules must be repaired before the upgraded scheduled task is registered or started.'
}
$registerSource = Get-Content -LiteralPath $register -Raw
foreach ($expected in @('New-ScheduledTaskTrigger -AtLogOn', 'New-ScheduledTaskPrincipal', '-LogonType Interactive', '-RunLevel Limited', 'New-ScheduledTaskAction -Execute $AgentPath', 'serve --managed-service --log-file', 'ExecutionTimeLimit ([TimeSpan]::Zero)', 'Stop-ScheduledTask -TaskName $TaskName', "State -in @('Running', 'Queued')", 'Scheduled task did not stop within 10 seconds')) {
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
    $env:MIMI_REGISTER_SCRIPT = $register
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
    -not $assignment.Right.Extent.Text.Contains('$AgentPath') -or
    -not $assignment.Right.Extent.Text.Contains('--managed-service')) {
    [Console]::Error.WriteLine('Windows PowerShell 5.1 did not parse the direct managed-service action.')
    exit 1
}
'@
    $encodedProbe = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($parserProbe))
    try {
        & $windowsPowerShell -NoLogo -NoProfile -NonInteractive -EncodedCommand $encodedProbe
        if ($LASTEXITCODE -ne 0) { throw 'Windows PowerShell 5.1 compatibility probe failed.' }
    } finally {
        if ($null -eq $previousRegisterScript) {
            Remove-Item Env:MIMI_REGISTER_SCRIPT -ErrorAction SilentlyContinue
        } else {
            $env:MIMI_REGISTER_SCRIPT = $previousRegisterScript
        }
    }
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
if (-not $buildSource.Contains('-X main.releaseVersion=$Version')) { throw 'Windows tray builds must embed the installer and GitHub Release version.' }
$checkSource = Get-Content -LiteralPath $check -Raw
if (-not $checkSource.Contains("'unsigned-release'")) { throw 'Installer validation must recognize unsigned release metadata.' }
$releaseSource = Get-Content -LiteralPath $releaseWorkflow -Raw
$currentRepositoryGate = "github.repository == 'gaixianggeng/mimi-remote'"
if (($releaseSource.Split($currentRepositoryGate).Count - 1) -lt 4) { throw 'All release jobs, including Windows compatibility verification, must target the source repository.' }
if (-not $releaseSource.Contains('-AllowUnsignedRelease')) { throw 'Release workflow must explicitly opt into unsigned Windows packaging when credentials are absent.' }
if (-not $releaseSource.Contains('must either both be configured or both be absent')) { throw 'Partial Windows signing credentials must fail the release.' }
if (-not $releaseSource.Contains('-RequireSignature')) { throw 'Release workflow must still enforce Authenticode when signing credentials exist.' }
foreach ($path in $windowsDocs) {
    $docSource = Get-Content -LiteralPath $path -Raw
    if (-not $docSource.Contains('MIM-207') -or -not $docSource.Contains('Windows')) {
        throw "Windows documentation must record the MIM-207 agentd host compatibility gate: $path"
    }
    if ($docSource -notmatch '(paused|暂停)') {
        throw "Windows documentation must state that installer publishing is paused: $path"
    }
}
# Static-only acceptance: do not invoke Setup.exe or schtasks.exe, so no real user task or firewall rule is created.
Write-Host 'Windows installer static/dry-run acceptance passed; no scheduled task or firewall rule was created.'

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or
    $env:GITHUB_REPOSITORY -ne 'gaixianggeng/mimi-remote' -or $env:GITHUB_REF -ne 'refs/heads/codex/gh-975-installer-acceptance') {
    throw 'This test intentionally changes the installed app and task. Run only on the dedicated GitHub-hosted Windows VM.'
}

$taskName = 'Mimi Remote agentd'
$install = Join-Path $env:LOCALAPPDATA 'Programs/Mimi Remote'
$configDir = Join-Path $env:APPDATA 'mimi-remote'
$out = Join-Path $env:RUNNER_TEMP 'installer-acceptance'
$oldName = 'Mimi-Remote-Setup-1.1.14-unsigned.exe'
$old = Join-Path $out $oldName
$new = Join-Path $out 'Mimi-Remote-Setup-1.1.15-acceptance.exe'
$exe = Join-Path $install 'agentd.exe'
$pidPath = Join-Path $env:LOCALAPPDATA 'Mimi Remote/agentd.pid'
$endpoint = 'http://127.0.0.1:8787'
if (Test-Path -LiteralPath $install) { throw 'Existing installed app found' }
if (Test-Path -LiteralPath $configDir) { throw 'Existing user configuration found' }
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { throw 'Existing app task found' }
if (Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue) { throw 'Test port is occupied' }

$release = 'https://github.com/gaixianggeng/mimi-remote/releases/download/v1.1.14'
$digest = 'ff58b584539be317c04393edd099d6d09a7799362d69fcfe3ecde43d341c916d'
Invoke-WebRequest -Uri "$release/$oldName" -OutFile $old
Invoke-WebRequest -Uri "$release/$oldName.sha256" -OutFile "$old.sha256"
if ((Get-FileHash -LiteralPath $old).Hash -ne $digest -or
    (Get-Content -LiteralPath "$old.sha256" -Raw).Trim() -ne "$digest  $oldName") {
    throw 'The official v1.1.14 baseline artifact does not match its pinned SHA-256.'
}

$project = Join-Path $out 'test-project'
New-Item -ItemType Directory -Path $configDir,$project | Out-Null
$configPath = Join-Path $configDir 'config.json'
$identityPath = Join-Path $configDir 'installation-id'
$token = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
@{
    listen = '127.0.0.1:8787'
    network = @{ allow_lan = $false }
    auth = @{ token = $token; allow_query_token = $false }
    runtime = @{ type = 'codex_app_server' }
    app_server = @{ transport = 'ssh'; ssh_target = '127.0.0.1' }
    codex = @{ enabled = $false }
    claude = @{ enabled = $false }
    deepseek = @{ enabled = $false }
    tailcat = @{ enabled = $false }
    projects = @(@{ id = 'acceptance'; name = 'Acceptance'; path = $project })
    browse_roots = @($project)
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM

function Invoke-Installer([string]$Path, [string]$Stage, [switch]$Uninstall) {
    $logPath = Join-Path $out (($Stage -replace ' ', '-') + '.log')
    $arguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG="' + $logPath + '"'
    if (-not $Uninstall) { $arguments += ' /SP- /MERGETASKS=!lanfirewall' }
    $process = Start-Process -FilePath $Path -ArgumentList $arguments -WindowStyle Hidden -PassThru
    try {
        if (-not $process.WaitForExit(150000)) { throw "$Stage timed out." }
        if ($process.ExitCode -ne 0) { throw "$Stage exited with $($process.ExitCode)." }
    } catch {
        foreach ($log in @($logPath, (Join-Path $env:LOCALAPPDATA 'Mimi Remote/logs/agentd.log'))) {
            if (Test-Path -LiteralPath $log) {
                Get-Content -LiteralPath $log -Tail 20 | ForEach-Object { $_.Replace($token, '[test credential]') } | Write-Host
            }
        }
        throw
    } finally { $process.Dispose() }
}

function Assert-Install([string]$Stage, [string]$Version, [bool]$UsesHost) {
    $expectedAction = if ($UsesHost) { 'mimi-agent-host.exe' } else { 'agentd.exe' }
    $task = Get-ScheduledTask -TaskName $taskName
    if (@($task.Actions).Count -ne 1 -or $task.Actions[0].Execute -ne (Join-Path $install $expectedAction) -or
        $task.Principal.RunLevel -ne 'Limited' -or $task.Principal.LogonType -ne 'Interactive') {
        throw "$Stage registered an unexpected task action or principal."
    }
    $status = & $exe status --json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $status.service_ok -or -not $status.process_ok -or
        $status.version -ne $Version -or $status.server_version -ne $Version) {
        throw "$Stage does not have the expected healthy installed service."
    }
    $headers = @{ Authorization = "Bearer $token" }
    $projects = Invoke-RestMethod -Uri "$endpoint/api/projects" -Headers $headers -NoProxy -TimeoutSec 10
    if ($projects.projects.id -notcontains 'acceptance') { throw "$Stage did not retain the existing project's access." }
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if ($config.auth.token -cne $token -or $config.listen -ne '127.0.0.1:8787' -or $config.network.allow_lan -eq $true) {
        throw "$Stage changed stored access or widened the listener."
    }
    if ($UsesHost) {
        $agentPid = [int](Get-Content -LiteralPath $pidPath -Raw).Trim()
        $agent = Get-CimInstance Win32_Process -Filter "ProcessId = $agentPid"
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId = $($agent.ParentProcessId)"
        if ($agent.ExecutablePath -ne $exe -or $parent.ExecutablePath -ne (Join-Path $install $expectedAction)) {
            throw "$Stage did not run the installed agent as a child of the installed GUI host."
        }
    }
    Write-Host "$Stage passed: expected task, healthy service, existing access, loopback only."
}

function Assert-Identity {
    if ((Get-FileHash -LiteralPath $identityPath).Hash -ne $identityHash) { throw 'The installation identity changed.' }
}

Invoke-Installer $old 'Install baseline'
Assert-Install 'Install baseline' '1.1.14' $false
$identityHash = (Get-FileHash -LiteralPath $identityPath).Hash

Invoke-Installer $new 'Upgrade to snapshot'
Assert-Install 'Upgrade to snapshot' '1.1.15-acceptance' $true
Assert-Identity

Invoke-Installer $old 'Roll back to baseline'
Assert-Install 'Roll back to baseline' '1.1.14' $false
Assert-Identity

Invoke-Installer $new 'Upgrade again'
Assert-Install 'Upgrade again' '1.1.15-acceptance' $true
Assert-Identity

$uninstaller = Get-ChildItem -LiteralPath $install -Filter 'unins*.exe' | Select-Object -First 1
if (-not $uninstaller) { throw 'No uninstaller was registered.' }
Invoke-Installer $uninstaller.FullName 'Uninstall snapshot' -Uninstall
for ($attempt = 0; $attempt -lt 20 -and (Test-Path -LiteralPath $exe); $attempt++) { Start-Sleep -Milliseconds 250 }
if ((Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) -or
    (Test-Path -LiteralPath $exe) -or (Test-Path -LiteralPath (Join-Path $install 'mimi-agent-host.exe')) -or
    (Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue)) {
    throw 'Uninstall left the task, binary, or listener behind.'
}
Assert-Identity
if ((Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json).auth.token -cne $token) { throw 'Uninstall changed the test credential.' }
Write-Host 'Uninstall passed: task, binary and listener removed; config and identity preserved.'

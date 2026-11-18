[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or
    $env:GITHUB_REPOSITORY -ne 'gaixianggeng/mimi-remote' -or $env:GITHUB_REF -ne 'refs/heads/codex/gh-979-signing-acceptance' -or
    $env:MIMI_FIXTURE_THUMBPRINT -notmatch '^[0-9A-F]{40}$') {
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
$native = Join-Path $install 'app/MimiRemote.exe'
$legacy = Join-Path $install 'mimi-remote-tray.exe'
$startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'Mimi Remote.lnk'
$menuLink = Join-Path ([Environment]::GetFolderPath('Programs')) 'Mimi Remote/Mimi Remote.lnk'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$desktopKey = 'HKCU:\Software\Mimi Remote'
$trayMutexName = 'Local\MimiRemoteTray-7D413E71-19C5-4F02-8AFC-437E1B8019FD'
$pidPath = Join-Path $env:LOCALAPPDATA 'Mimi Remote/agentd.pid'
$endpoint = 'http://127.0.0.1:8787'
if (Test-Path -LiteralPath $install) { throw 'Existing installed app found' }
if (Test-Path -LiteralPath $configDir) { throw 'Existing user configuration found' }
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { throw 'Existing app task found' }
if (Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue) { throw 'Test port is occupied' }
if (Test-Path -LiteralPath $startupLink) { throw 'Existing startup entry found' }
$session = [Diagnostics.Process]::GetCurrentProcess().SessionId
if ($session -eq 0) { throw 'Tray acceptance requires an interactive desktop session.' }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class DesktopProbe {
    private delegate bool Visit(IntPtr hwnd, IntPtr state);
    [DllImport("user32.dll")] private static extern bool EnumWindows(Visit callback, IntPtr state);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint process);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int size);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string className, string title);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint message, UIntPtr wParam, IntPtr lParam);
    public static IntPtr MainWindow(uint expectedProcess) {
        IntPtr result = IntPtr.Zero;
        EnumWindows((hwnd, _) => {
            GetWindowThreadProcessId(hwnd, out uint process);
            if (process != expectedProcess) return true;
            var title = new StringBuilder(256);
            GetWindowText(hwnd, title, title.Capacity);
            if (title.ToString() != "Mimi Remote") return true;
            result = hwnd;
            return false;
        }, IntPtr.Zero);
        return result;
    }
}
'@

function Await([string]$Description, [scriptblock]$Condition) {
    $deadline = [DateTime]::UtcNow.AddSeconds(25)
    do {
        $result = & $Condition
        if ($result) { return $result }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $Description."
}
if ([DesktopProbe]::FindWindow('Shell_TrayWnd', $null) -eq [IntPtr]::Zero) {
    Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -WindowStyle Hidden
}
Await 'Explorer notification area in the runner session' { [DesktopProbe]::FindWindow('Shell_TrayWnd', $null) -ne [IntPtr]::Zero } | Out-Null

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
    tailcat = @{ enabled = $false; mode = 'managed' }
    projects = @(@{ id = 'acceptance'; name = 'Acceptance'; path = $project })
    browse_roots = @($project)
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM
$tailcatState = Join-Path $configDir 'tailcat'
New-Item -ItemType Directory -Path $tailcatState | Out-Null
$mobileKey = 'nodekey:' + ('35' * 32)
'["' + $mobileKey + '"]' | Set-Content -LiteralPath (Join-Path $tailcatState 'clients.json') -Encoding utf8NoBOM
@{ private_key = 'privkey:' + ('19' * 32); address = 'acceptance-fixture' } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $tailcatState 'host.private.json') -Encoding utf8NoBOM
'acceptance-fixture' | Set-Content -LiteralPath (Join-Path $tailcatState 'host.address') -Encoding utf8NoBOM
@{
    version = 1
    host_id = [Guid]::NewGuid().ToString()
    host_device_token = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    mac_tailcat_public_key = 'nodekey:' + ('27' * 32)
    policy_version = 1
    allowed_mobile_tailcat_public_keys = @($mobileKey)
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $tailcatState 'managed-policy.json') -Encoding utf8NoBOM
$savedFiles = @{}
foreach ($file in Get-ChildItem -LiteralPath $tailcatState -File) {
    $savedFiles[$file.FullName] = (Get-FileHash -LiteralPath $file.FullName).Hash
}

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
    foreach ($entry in $savedFiles.GetEnumerator()) {
        if ((Get-FileHash -LiteralPath $entry.Key).Hash -ne $entry.Value) { throw 'A saved Tailcat identity, client list or relay policy changed.' }
    }
}

function Assert-WorkspaceRollback {
    $previous = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $selected = Join-Path $out 'second project'
    New-Item -ItemType Directory -Path $selected | Out-Null
    $transaction = & $exe workspace --root $selected --json | Out-String
    if ($LASTEXITCODE -ne 0 -or -not ($transaction | ConvertFrom-Json).changed) { throw 'Workspace change did not apply.' }
    & $exe workspace --restore-state $transaction --json | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'The original workspace transaction output could not be restored.' }
    $restored = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if (($restored.scan_roots | ConvertTo-Json -Compress) -cne ($previous.scan_roots | ConvertTo-Json -Compress) -or
        ($restored.browse_roots | ConvertTo-Json -Compress) -cne ($previous.browse_roots | ConvertTo-Json -Compress) -or
        $restored.auth.token -cne $token) {
        throw 'Workspace rollback changed the saved roots or credential.'
    }
    Write-Host 'Installed CLI workspace rollback passed using the original formatted JSON output.'
}

function Assert-Shortcut([string]$Link, [string]$Image, [string]$Arguments) {
    if (-not (Test-Path -LiteralPath $Link -PathType Leaf)) { throw 'The expected shell shortcut does not exist.' }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Link)
    if ($shortcut.TargetPath -ne $Image -or $shortcut.Arguments.Trim() -ne $Arguments -or
        $shortcut.WorkingDirectory.TrimEnd('\') -ne (Split-Path -Parent $Image)) {
        throw "Wrong target, arguments or working directory for $([IO.Path]::GetFileName($Link))."
    }
}

function Get-DesktopIds([string]$Image) {
    $name = [IO.Path]::GetFileName($Image)
    Get-CimInstance Win32_Process -Filter "Name = '$name'" |
        Where-Object { $_.ExecutablePath -eq $Image -and $_.SessionId -eq $session } |
        Select-Object -ExpandProperty ProcessId
}

function Assert-DesktopIdle([string]$Image) {
    Await "installed desktop process $([IO.Path]::GetFileName($Image)) to exit" { @(Get-DesktopIds $Image).Count -eq 0 } | Out-Null
}

function Start-LegacyTray {
    Assert-Shortcut $startupLink $legacy ''
    Assert-Shortcut $menuLink $legacy '--show'
    Start-Process -FilePath $startupLink
    $legacyId = Await 'legacy tray to start from the login shortcut' { Get-DesktopIds $legacy }
    Start-Sleep -Seconds 1
    if (@(Get-DesktopIds $legacy).Count -ne 1 -or -not (Get-Process -Id $legacyId -ErrorAction SilentlyContinue)) {
        throw 'Exactly one initialized legacy tray must remain running.'
    }
    Assert-DesktopIdle $native
    Write-Host 'Legacy login and Start menu shortcuts restored. Legacy tray initialized.'
}

function Assert-FixtureSignatures([string[]]$Paths) {
    foreach ($path in $Paths) {
        $signature = Get-AuthenticodeSignature -LiteralPath $path
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -ne $env:MIMI_FIXTURE_THUMBPRINT -or
            $null -eq $signature.TimeStamperCertificate) {
            throw "Missing trusted, timestamped fixture signature on $([IO.Path]::GetFileName($path)): $($signature.Status)"
        }
    }
    Write-Host "Verified timestamped fixture signatures for $($Paths.Count) executable(s)."
}

function Assert-NativePayload {
    if ((Test-Path -LiteralPath $legacy) -or (Get-ItemProperty -LiteralPath $runKey -Name MimiRemoteNative -ErrorAction SilentlyContinue)) {
        throw 'The upgrade retained a legacy tray image or obsolete preview Run entry.'
    }
    $metadata = Get-Content -LiteralPath "$new.metadata.json" -Raw | ConvertFrom-Json -AsHashtable
    if ($metadata.signing -ne 'authenticode-pfx' -or (Get-Item -LiteralPath $native).VersionInfo.ProductVersion -ne $metadata.version) {
        throw 'The installed desktop version is inconsistent with the release metadata.'
    }
    foreach ($entry in $metadata.payload_sha256.GetEnumerator()) {
        $file = Join-Path $install $entry.Key
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $entry.Value) { throw "Installed payload differs: $($entry.Key)" }
    }
    Assert-FixtureSignatures (@($new) + @($metadata.binaries | ForEach-Object { Join-Path $install $_ }))
    Write-Host "Installed payload matches all $($metadata.payload_sha256.Count) manifest hashes."
}

function Await-NativeWindow([uint32]$ProcessId, [bool]$Visible) {
    Await "WinUI window visibility $Visible" {
        $handle = [DesktopProbe]::MainWindow($ProcessId)
        if ($handle -ne [IntPtr]::Zero -and [DesktopProbe]::IsWindowVisible($handle) -eq $Visible) { $handle }
    }
}

function Assert-NativeTray {
    Assert-Shortcut $startupLink $native '--background'
    Assert-Shortcut $menuLink $native ''
    Start-Process -FilePath $startupLink
    $processId = Await 'WinUI to start from its login shortcut' { Get-DesktopIds $native }
    $null = Await-NativeWindow $processId $false
    Start-Sleep -Seconds 1
    $null = Await-NativeWindow $processId $false
    $trayMutex = [Threading.Mutex]::OpenExisting($trayMutexName)
    $trayMutex.Dispose()
    Assert-DesktopIdle $legacy
    Write-Host 'WinUI login shortcut initialized the tray with a hidden main window.'

    Start-Process -FilePath $menuLink
    $window = Await-NativeWindow $processId $true
    Await 'only the original WinUI instance after Start menu activation' { @(Get-DesktopIds $native).Count -eq 1 } | Out-Null
    Start-Process -FilePath $startupLink
    Start-Sleep -Seconds 2
    $null = Await-NativeWindow $processId $true
    Await 'only the original WinUI instance after repeated login activation' { @(Get-DesktopIds $native).Count -eq 1 } | Out-Null
    if (-not [DesktopProbe]::PostMessage($window, 0x0010, [UIntPtr]::Zero, [IntPtr]::Zero)) { throw 'Could not close the WinUI window.' }
    $null = Await-NativeWindow $processId $false
    Start-Process -FilePath $menuLink
    $null = Await-NativeWindow $processId $true
    Write-Host 'Start menu reactivated the same WinUI instance. Closing hid it to the tray, and repeated login activation kept one instance.'
}

Invoke-Installer $old 'Install baseline'
Assert-Install 'Install baseline' '1.1.14' $false
$identityHash = (Get-FileHash -LiteralPath $identityPath).Hash
Assert-Identity
Start-LegacyTray
New-ItemProperty -LiteralPath $runKey -Name MimiRemoteNative -Value '"C:\isolation-fixture\MimiRemote.exe" --background' -PropertyType String -Force | Out-Null

Invoke-Installer $new 'Upgrade to snapshot'
Assert-Install 'Upgrade to snapshot' '1.1.15-acceptance' $true
Assert-Identity
Assert-DesktopIdle $legacy
Assert-NativePayload
& (Join-Path $PSScriptRoot 'test-claude-adapter-windows.ps1') -AdapterPath (Join-Path $install 'mimi-claude-adapter.exe')
Assert-WorkspaceRollback
Assert-NativeTray

Invoke-Installer $old 'Roll back to baseline'
Assert-Install 'Roll back to baseline' '1.1.14' $false
Assert-Identity
Assert-DesktopIdle $native
Start-LegacyTray
if (Test-Path -LiteralPath $native) {
    $stale = Start-Process -FilePath $native -PassThru
    try { if (-not $stale.WaitForExit(10000)) { throw 'Residual WinUI can still start after rollback.' } }
    finally { $stale.Dispose() }
    Write-Host 'Rollback left the native files on disk. The rolled-back installation rejects their activation.'
}

Invoke-Installer $new 'Upgrade again'
Assert-Install 'Upgrade again' '1.1.15-acceptance' $true
Assert-Identity
Assert-NativePayload
Assert-NativeTray

New-Item -Path $desktopKey -Force | Out-Null
New-ItemProperty -LiteralPath $desktopKey -Name DesktopStartupDisabled -Value 1 -PropertyType DWord -Force | Out-Null
Invoke-Installer $new 'Repair with startup disabled'
Assert-Install 'Repair with startup disabled' '1.1.15-acceptance' $true
Assert-DesktopIdle $native
Assert-Shortcut $menuLink $native ''
if (Test-Path -LiteralPath $startupLink) { throw 'Repair re-enabled the opted-out login shortcut.' }
Start-Process -FilePath $menuLink
$processId = Await 'WinUI to start manually with login disabled' { Get-DesktopIds $native }
$null = Await-NativeWindow $processId $true
Write-Host 'Repair preserved the disabled login preference and the Start menu launch.'

$uninstaller = Get-ChildItem -LiteralPath $install -Filter 'unins*.exe' | Select-Object -First 1
if (-not $uninstaller) { throw 'No uninstaller was registered.' }
Assert-FixtureSignatures @($uninstaller.FullName)
Invoke-Installer $uninstaller.FullName 'Uninstall snapshot' -Uninstall
for ($attempt = 0; $attempt -lt 20 -and (Test-Path -LiteralPath $exe); $attempt++) { Start-Sleep -Milliseconds 250 }
if ((Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) -or
    (Test-Path -LiteralPath $exe) -or (Test-Path -LiteralPath (Join-Path $install 'mimi-agent-host.exe')) -or
    (Test-Path -LiteralPath $native) -or (Test-Path -LiteralPath $legacy) -or
    (Test-Path -LiteralPath $menuLink) -or (Test-Path -LiteralPath $startupLink) -or
    (Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue)) {
    throw 'Uninstall left the task, binary, or listener behind.'
}
Assert-Identity
Assert-DesktopIdle $native
Assert-DesktopIdle $legacy
if ((Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json).auth.token -cne $token) { throw 'Uninstall changed the test credential.' }
Write-Host 'Uninstall passed: task, binaries, shortcuts, processes and listener removed; config, installation ID and Tailcat state preserved.'

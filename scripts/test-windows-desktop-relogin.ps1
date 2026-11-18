[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InstallerPath,
    [Parameter(Mandatory=$true)][string]$ResultPath,
    [Parameter(Mandatory=$true)][ValidateSet(19045,26300)][int]$ExpectedBuild,
    [ValidatePattern('^COM[1-9][0-9]?$')][string]$ResultPort,
    [switch]$Observe
)

$ErrorActionPreference = 'Stop'
$probeName = 'Mimi Remote logon acceptance 979'
$marker = 'gh979-desktop-oem-v1'
$profileDir = Join-Path $env:LOCALAPPDATA 'Mimi-Remote-Logon-Acceptance-979'
$statePath = Join-Path $profileDir 'state.json'
$sentinelPath = Join-Path $profileDir 'startup-sentinel'
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\Mimi Remote'
$configDir = Join-Path $env:APPDATA 'mimi-remote'
$configPath = Join-Path $configDir 'config.json'
$identityPath = Join-Path $configDir 'installation-id'
$agentPath = Join-Path $installDir 'agentd.exe'
$hostPath = Join-Path $installDir 'mimi-agent-host.exe'
$appDir = Join-Path $installDir 'app'
$winuiPath = Join-Path $appDir 'MimiRemote.exe'
$startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'Mimi Remote.lnk'
$menuLink = Join-Path ([Environment]::GetFolderPath('Programs')) 'Mimi Remote\Mimi Remote.lnk'
$principal = [Security.Principal.WindowsIdentity]::GetCurrent()
$session = (Get-Process -Id $PID).SessionId
$build = 0
$revision = 0
$step = 'guard'
$previousState = $null
$reportAllowed = $false
$installerExit = $null

function Publish-Result([string]$Status, [hashtable]$Detail = @{}) {
    $result = [ordered]@{
        schema = 1
        status = $Status
        phase = $script:step
        expectedBuild = $ExpectedBuild
        build = $script:build
        revision = $script:revision
        transition = 'logoff'
        utc = [DateTime]::UtcNow.ToString('o')
    }
    foreach ($key in $Detail.Keys) { $result[$key] = $Detail[$key] }
    $json = $result | ConvertTo-Json -Compress
    if ($json.Length -gt 1024) { throw 'Result exceeds the schema size limit.' }
    if ($ResultPort) {
        try {
            $port = [System.IO.Ports.SerialPort]::new($ResultPort, 115200, 'None', 8, 'One')
            try {
                $port.WriteTimeout = 2500
                $port.Open()
                $port.WriteLine("MIMI_RELOGIN_RESULT=$json")
            } finally { $port.Dispose() }
        } catch { Write-Warning 'Serial result delivery failed.' }
    }
    try {
        $tempPath = "$ResultPath.$PID.tmp"
        [IO.File]::WriteAllText($tempPath, $json)
        if ([IO.File]::Exists($ResultPath)) { [IO.File]::Replace($tempPath, $ResultPath, $null) }
        else { [IO.File]::Move($tempPath, $ResultPath) }
    } catch { Write-Warning 'Guest result file delivery failed.' }
}

function Get-LogonId {
    $output = & (Join-Path $env:WINDIR 'System32\whoami.exe') /logonid 2>$null
    $match = [regex]::Match(($output -join ' '), 'S-1-5-5-\d+-\d+')
    if ($LASTEXITCODE -ne 0 -or -not $match.Success) { throw 'Could not read the interactive logon SID.' }
    $match.Value
}

function Test-InteractiveExplorer {
    @(Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session }).Count -ge 1
}

function Wait-Condition([int]$Seconds, [scriptblock]$Test) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        if (& $Test) { return }
        Start-Sleep -Milliseconds 350
    } while ($timer.Elapsed.TotalSeconds -lt $Seconds)
    throw 'Condition did not become true before its deadline.'
}

function Get-UiProcesses {
    Get-CimInstance Win32_Process -Filter "Name = 'MimiRemote.exe' AND SessionId = $session" |
        Where-Object { $_.ExecutablePath -ieq $winuiPath }
}

function Test-NoLegacyTray {
    @(Get-Process -Name 'mimi-remote-tray' -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session }).Count -eq 0
}

function Assert-Shortcut([string]$Path, [string]$Arguments) {
    if (-not [IO.File]::Exists($Path)) { throw 'Expected installed .lnk is absent.' }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    try {
        if ($shortcut.TargetPath -ine $winuiPath -or $shortcut.Arguments -cne $Arguments -or
            $shortcut.WorkingDirectory -ine $appDir) {
            throw 'Shortcut command or working directory did not match expected installation.'
        }
    } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

function Get-StringHash([string]$Value) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))) }
    finally { $sha.Dispose() }
}

function Get-AgentStatus {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $agentPath
    $info.Arguments = 'status --json'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(8000)) {
            $process.Kill()
            return $null
        }
        if ($process.ExitCode -ne 0) { return $null }
        $stdout.GetAwaiter().GetResult() | ConvertFrom-Json
    } finally { $process.Dispose() }
}

function Assert-Backend {
    $backend = Get-ScheduledTask -TaskName 'Mimi Remote agentd'
    $actions = @($backend.Actions)
    $triggers = @($backend.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' })
    if ($actions.Count -ne 1 -or $actions[0].Execute -ine $hostPath -or
        $backend.Principal.RunLevel -ne 'Limited' -or $backend.Principal.LogonType -ne 'Interactive' -or $triggers.Count -ne 1) {
        throw 'Wrong installed backend action, logon trigger, or principal.'
    }
    Wait-Condition 55 {
        try {
            $status = Get-AgentStatus
            $status -and $status.service_ok -and $status.process_ok -and $status.version -eq $status.server_version
        } catch { $false }
    }
    $listeners = @(Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue)
    if ($listeners.Count -lt 1 -or @($listeners | Where-Object { $_.LocalAddress -ne '127.0.0.1' }).Count -ne 0) {
        throw 'Backend did not bind only to the fixture loopback address.'
    }
    $agentPidFile = Join-Path $env:LOCALAPPDATA 'Mimi Remote\agentd.pid'
    $agentPid = [int]([IO.File]::ReadAllText($agentPidFile).Trim())
    $agent = Get-CimInstance Win32_Process -Filter "ProcessId = $agentPid"
    if (-not $agent -or $agent.ExecutablePath -ine $agentPath -or $agent.SessionId -ne $session) {
        throw 'Service PID did not identify the installed backend in this login session.'
    }
    $parent = Get-CimInstance Win32_Process -Filter "ProcessId = $($agent.ParentProcessId)"
    if (-not $parent -or $parent.ExecutablePath -ine $hostPath -or $parent.SessionId -ne $session) {
        throw 'Backend was not started by the installed native host.'
    }
    if ($Observe -and ($agent.CreationDate.ToUniversalTime() -lt [DateTime]::Parse($previousState.departureUtc).ToUniversalTime())) {
        throw 'Backend predated the first session ending.'
    }
}

function Assert-Fixture {
    $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if ($cfg.listen -ne '127.0.0.1:8787' -or $cfg.network.allow_lan -or $cfg.tailcat.enabled -or
        $cfg.auth.allow_query_token -or (Get-StringHash $cfg.auth.token) -cne $previousState.tokenHash -or
        (Get-FileHash -LiteralPath $identityPath).Hash -cne $previousState.identityHash) {
        throw 'Fixture access or installation ID did not survive.'
    }
    $request = [Net.HttpWebRequest]::Create('http://127.0.0.1:8787/api/projects')
    $request.Proxy = $null
    $request.Timeout = 10000
    $request.Headers['Authorization'] = "Bearer $($cfg.auth.token)"
    $response = $request.GetResponse()
    try {
        $reader = New-Object IO.StreamReader($response.GetResponseStream())
        try { $projects = $reader.ReadToEnd() | ConvertFrom-Json }
        finally { $reader.Dispose() }
        if ($projects.projects.id -notcontains 'acceptance') { throw 'Authenticated fixture project was not reachable.' }
    } finally { $response.Dispose() }
}

function Add-WindowProbe {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class MimiLogonAcceptanceWindow {
    private delegate bool EnumerateWindow(IntPtr window, IntPtr data);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumerateWindow callback, IntPtr data);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr window, StringBuilder text, int size);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr FindWindow(string className, string title);

    public static bool HasTaskbar() { return FindWindow("Shell_TrayWnd", null) != IntPtr.Zero; }

    public static int State(uint processId) {
        int state = 0;
        EnumWindows(delegate (IntPtr window, IntPtr data) {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner != processId) return true;
            StringBuilder title = new StringBuilder(128);
            if (GetWindowText(window, title, title.Capacity) == 0 || title.ToString() != "Mimi Remote") return true;
            state = Math.Max(state, IsWindowVisible(window) ? 2 : 1);
            return state != 2;
        }, IntPtr.Zero);
        return state;
    }
}
'@
}

function Publish-TrayDiagnostics([string]$Source) {
    $processes = @(Get-CimInstance Win32_Process -Filter "Name = 'MimiRemote.exe'")
    $clients = @(Get-UiProcesses)
    $reg = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{7D413E71-19C5-4F02-8AFC-437E1B8019FD}_is1' -ErrorAction SilentlyContinue
    $approved = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' -Name 'Mimi Remote.lnk' -ErrorAction SilentlyContinue
    $approvedByte = if ($approved.'Mimi Remote.lnk') { $approved.'Mimi Remote.lnk'[0] } else { $null }
    $events = @(Get-WinEvent -FilterHashtable @{ LogName='Application'; Id=33,1000,1001,1026; StartTime=[DateTime]::Parse($previousState.departureUtc).ToLocalTime() } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'MimiRemote' } | Select-Object -First 4)
    $faults = @()
    foreach ($event in $events) {
        $module = [regex]::Match($event.Message, '(?im)Faulting module name:\s+([\w.-]+)').Groups[1].Value
        $code = [regex]::Match($event.Message, '(?im)Exception code:\s+(0x[0-9a-f]+)').Groups[1].Value
        $exception = [regex]::Match($event.Message, '(?im)Exception Info:\s+([\w.]+)').Groups[1].Value
        $faults += "$($event.Id):$module/$code/$exception"
    }
    Publish-Result 'diagnosing' @{
        source = $Source
        totalWinUi = $processes.Count
        matchingWinUi = $clients.Count
        matchingWindowStates = @($clients | ForEach-Object { [MimiLogonAcceptanceWindow]::State($_.ProcessId) })
        taskbar = [MimiLogonAcceptanceWindow]::HasTaskbar()
        approved = $approvedByte
        shellStartedSentinel = (Test-Path -LiteralPath $sentinelPath)
        registeredInstall = (([string]$reg.InstallLocation).TrimEnd('\') -ieq $installDir)
        faults = $faults
    }
}

try {
    if ($PSCommandPath -notlike 'C:\OEM\*' -or $ResultPath -notlike 'C:\OEM\*' -or
        ($principal.Name -split '\\')[-1] -ne 'MimiFixture') {
        throw 'Expected an OEM execution path and an absolute result path.'
    }
    if ($Observe) {
        $previousState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($previousState.marker -cne $marker -or $previousState.account -cne $principal.User.Value) {
            throw 'Dedicated guest state is missing.'
        }
    } elseif ($env:MIMI_WIN_LOGON_ACCEPTANCE -cne $marker) {
        throw 'Dedicated OEM guest marker is missing.'
    }
    $os = Get-CimInstance Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    $revision = [int](Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name UBR)
    if ($os.ProductType -ne 1 -or $session -eq 0 -or -not [Environment]::Is64BitOperatingSystem) {
        throw 'Expected an interactive 64-bit desktop Windows guest.'
    }
    $reportAllowed = $true
    if ($build -ne $ExpectedBuild) { throw 'The actual Windows build does not match.' }
    if ($Observe) {
        $step = 'check-new-logon'
        if ($previousState.expectedBuild -ne $ExpectedBuild -or $previousState.phase -cne 'awaiting-logon' -or
            (Get-LogonId) -ceq $previousState.logonId) {
            throw 'No genuine second interactive logon was detected.'
        }
        $step = 'check-explorer'
        Wait-Condition 75 { Test-InteractiveExplorer }
        $step = 'check-installed-shortcuts'
        Assert-Shortcut $startupLink '--background'
        Assert-Shortcut $menuLink ''
        $step = 'check-tray-started-at-logon'
        Add-WindowProbe
        try {
            Wait-Condition 180 {
                $tray = @(Get-UiProcesses)
                $tray.Count -eq 1 -and [MimiLogonAcceptanceWindow]::State($tray[0].ProcessId) -gt 0
            }
        } catch {
            Publish-TrayDiagnostics 'automatic-logon'
            $child = Start-Process -FilePath $winuiPath -ArgumentList '--background' -WorkingDirectory $appDir -PassThru
            try {
                if ($child.WaitForExit(12000)) {
                    $code = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$child.ExitCode), 0)
                    Publish-Result 'diagnosing' @{ source='explicit-launch-exit'; exitCode=('0x{0:X8}' -f $code) }
                }
                Publish-TrayDiagnostics 'after-explicit-launch'
            } finally { $child.Dispose() }
            throw 'The WinUI startup did not occur automatically.'
        }
        $client = @(Get-UiProcesses)
        if ($client.Count -ne 1 -or -not (Test-NoLegacyTray) -or
            [MimiLogonAcceptanceWindow]::State($client[0].ProcessId) -ne 1 -or
            $client[0].CommandLine -cnotmatch '(?:^|\s)--background(?:\s|$)' -or
            $client[0].CreationDate.ToUniversalTime() -lt [DateTime]::Parse($previousState.departureUtc).ToUniversalTime()) {
            throw 'WinUI did not start exactly once in background at the second logon.'
        }
        $trayPid = $client[0].ProcessId
        $step = 'check-backend-started-at-logon'
        Assert-Backend
        $step = 'check-fixture'
        Assert-Fixture
        $step = 'check-start-menu-activation'
        if ([MimiLogonAcceptanceWindow]::State($trayPid) -ne 1) {
            throw 'The same WinUI window must still be hidden before opening Start.'
        }
        Start-Process -FilePath $menuLink
        Wait-Condition 25 {
            $clients = @(Get-UiProcesses)
            $clients.Count -eq 1 -and $clients[0].ProcessId -eq $trayPid -and [MimiLogonAcceptanceWindow]::State($trayPid) -eq 2
        }
        if (-not (Test-NoLegacyTray)) { throw 'A legacy tray process is active.' }
        $step = 'accepted'
        Publish-Result 'passed' @{
            newLogon = $true
            explorer = $true
            trayBackground = $true
            oneNativeProcess = $true
            sameInstanceVisible = $true
            nativeBackend = $true
            localAccessAndIdentityPreserved = $true
        }
    } else {
        $step = 'ensure-pristine-guest'
        if ((Test-Path -LiteralPath $profileDir) -or (Test-Path -LiteralPath $installDir) -or
            (Test-Path -LiteralPath $configDir) -or
            (Get-ScheduledTask -TaskName $probeName -ErrorAction SilentlyContinue) -or
            (Get-ScheduledTask -TaskName 'Mimi Remote agentd' -ErrorAction SilentlyContinue) -or
            (Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue) -or
            (Test-Path -LiteralPath $startupLink) -or (Test-Path -LiteralPath $menuLink) -or
            -not (Test-NoLegacyTray)) {
            throw 'An existing install, probe, shortcut, or listener was detected.'
        }
        $installer = Get-Item -LiteralPath $InstallerPath
        if ($installer.PSIsContainer -or $installer.Extension -ine '.exe' -or $installer.FullName -notlike 'C:\OEM\*') {
            throw 'Expected fixture setup executable under the OEM payload directory.'
        }
        $step = 'wait-for-first-explorer'
        Wait-Condition 75 { Test-InteractiveExplorer }
        $step = 'seed-fixture'
        $projectDir = Join-Path $profileDir 'test-project'
        New-Item -ItemType Directory -Path $profileDir,$projectDir,$configDir | Out-Null
        $random = [Security.Cryptography.RandomNumberGenerator]::Create()
        try {
            $bytes = New-Object byte[] 32
            $random.GetBytes($bytes)
            $token = [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
        } finally { $random.Dispose() }
        $fixture = @{
            listen = '127.0.0.1:8787'
            network = @{ allow_lan = $false }
            auth = @{ token = $token; allow_query_token = $false }
            runtime = @{ type = 'codex_app_server' }
            app_server = @{ transport = 'ssh'; ssh_target = '127.0.0.1' }
            codex = @{ enabled = $false }
            claude = @{ enabled = $false }
            deepseek = @{ enabled = $false }
            tailcat = @{ enabled = $false }
            projects = @(@{ id = 'acceptance'; name = 'Acceptance'; path = $projectDir })
            browse_roots = @($projectDir)
        }
        [IO.File]::WriteAllText($configPath, ($fixture | ConvertTo-Json -Depth 8))
        $step = 'install'
        $installLog = Join-Path $profileDir 'setup.log'
        $options = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /MERGETASKS=!lanfirewall /LOG="{0}"' -f $installLog
        $setup = Start-Process -FilePath $installer.FullName -ArgumentList $options -WindowStyle Hidden -PassThru
        try {
            if (-not $setup.WaitForExit(165000)) { throw 'Installer time limit exceeded.' }
            $installerExit = $setup.ExitCode
            if ($installerExit -ne 0) { throw 'Installer returned a nonzero result.' }
        } finally { $setup.Dispose() }
        $step = 'check-install-and-shortcuts'
        Assert-Backend
        Assert-Shortcut $startupLink '--background'
        Assert-Shortcut $menuLink ''
        if (@(Get-UiProcesses).Count -ne 0 -or -not (Test-NoLegacyTray)) { throw 'Tray was already active before logout.' }
        $sentinelLink = Join-Path (Split-Path -Parent $startupLink) 'Mimi fixture startup sentinel.lnk'
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut($sentinelLink)
        try {
            $link.TargetPath = Join-Path $PSHOME 'powershell.exe'
            $link.Arguments = '-NoProfile -WindowStyle Hidden -Command "[IO.File]::WriteAllText(''{0}'',''started'')"' -f $sentinelPath
            $link.Save()
        } finally {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($link)
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        }
        $step = 'register-observer'
        $observerArguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -InstallerPath "{1}" -ResultPath "{2}" -ExpectedBuild {3} -Observe' -f $PSCommandPath,$installer.FullName,$ResultPath,$ExpectedBuild
        if ($ResultPort) { $observerArguments += " -ResultPort $ResultPort" }
        $observer = New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'powershell.exe') -Argument $observerArguments
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $principal.Name
        $identity = New-ScheduledTaskPrincipal -UserId $principal.Name -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::FromMinutes(5)) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $probeName -Action $observer -Trigger $trigger -Principal $identity -Settings $settings | Out-Null
        $state = @{
            phase = 'awaiting-logon'
            marker = $marker
            account = $principal.User.Value
            expectedBuild = $ExpectedBuild
            logonId = Get-LogonId
            departureUtc = [DateTime]::UtcNow.ToString('o')
            identityHash = (Get-FileHash -LiteralPath $identityPath).Hash
            tokenHash = Get-StringHash $token
        }
        [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Compress))
        # Only the dedicated fixture account reaches this point. Preserve guest autologon on logoff.
        $winlogon = 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon'
        New-ItemProperty -LiteralPath $winlogon -Name ForceAutoLogon -PropertyType String -Value '1' -Force | Out-Null
        $step = 'awaiting-logon'
        Publish-Result 'awaiting-logon'
        $step = 'end-first-logon'
        $shutdown = Join-Path $env:WINDIR 'System32\shutdown.exe'
        & $shutdown /l
        if ($LASTEXITCODE -ne 0) { throw 'Windows declined ending the first session.' }
    }
} catch {
    if ($reportAllowed) {
        Publish-Result 'failed' @{
            errorClass = $_.Exception.GetType().Name
            line = $_.InvocationInfo.ScriptLineNumber
            installerExit = $installerExit
        }
    }
    Write-Error "The acceptance probe failed in phase $step." -ErrorAction Continue
    exit 1
} finally {
    if ($Observe -and $reportAllowed) {
        Unregister-ScheduledTask -TaskName $probeName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$HostPath,
    [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$HostPath = (Resolve-Path -LiteralPath $HostPath).Path
if (-not ('ConsoleWindowProbe' -as [type])) {
    Add-Type -Path (Join-Path $root 'windows/tests/ConsoleWindowProbe.cs')
}
# The positive control intentionally creates a visible console in this test session.
$probe = [ConsoleWindowProbe]::new()
$control = $null
try {
    $control = [ConsoleWindowProbe]::StartPositiveControl()
    $controlDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while ($probe.Count -eq 0 -and [DateTime]::UtcNow -lt $controlDeadline) { Start-Sleep -Milliseconds 25 }
    if ($probe.Count -eq 0) { throw 'Positive control was not visible: this desktop cannot certify absence of console windows.' }
} finally {
    if ($control -and -not $control.HasExited) { $control.Kill($true); $control.WaitForExit() }
    if ($control) { $control.Dispose() }
    $probe.Dispose()
}
if ($SelfTest) { Write-Host 'Console observation positive control passed.'; return }

$work = Join-Path ([IO.Path]::GetTempPath()) ('mimi-host-test-' + [guid]::NewGuid().ToString('N'))
$directory = Join-Path $work 'host with spaces'
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$hostBinary = Join-Path $directory 'mimi-agent-host.exe'
$agentBinary = Join-Path $directory 'agentd.exe'
Copy-Item -LiteralPath $HostPath -Destination $hostBinary
Push-Location $root
try {
    & go build -o $agentBinary ./windows/tests/testdata/fakeagentd
    if ($LASTEXITCODE -ne 0) { throw 'Fake agent build failed.' }
} finally { Pop-Location }
& (Join-Path $PSScriptRoot 'check-windows-host-subsystem.ps1') -Path $hostBinary -Expected GUI
& (Join-Path $PSScriptRoot 'check-windows-host-subsystem.ps1') -Path $agentBinary -Expected Console

function Start-TestHost([string[]]$Arguments, [string]$Mode) {
    $start = [Diagnostics.ProcessStartInfo]::new($hostBinary)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.Environment['LOCALAPPDATA'] = $work
    $start.Environment['MIMI_HOST_TEST_MODE'] = $Mode
    $start.Environment['MIMI_HOST_TEST_REPORT'] = (Join-Path $work 'report.json')
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    return [Diagnostics.Process]::Start($start)
}
function Assert-Exit([string[]]$Arguments, [int]$Expected, [string]$Mode = 'exit') {
    $process = Start-TestHost $Arguments $Mode
    try {
        if (-not $process.WaitForExit(10000)) { throw 'Host did not exit within 10 seconds.' }
        if ($process.ExitCode -ne $Expected) { throw "Expected exit $Expected, got $($process.ExitCode)." }
    } finally {
        if (-not $process.HasExited) { $process.Kill($true) }
        $process.Dispose()
    }
}
Assert-Exit @('--unexpected=private-test-value') 64
$errorPath = Join-Path $work 'Mimi Remote/agent-host.last-error.log'
if ((Get-Content -LiteralPath $errorPath -Raw).Contains('private-test-value')) { throw 'Host error leaked an argument value.' }
if ((Get-Item -LiteralPath $errorPath).Length -gt 4096) { throw 'Host error exceeded 4 KiB.' }
Rename-Item -LiteralPath $agentBinary -NewName 'agentd.missing.exe'
try { Assert-Exit @('--log-file', 'test.log') 69 }
finally { Rename-Item -LiteralPath (Join-Path $directory 'agentd.missing.exe') -NewName 'agentd.exe' }
Assert-Exit @('--log-file', 'test.log') 42

Start-Sleep -Milliseconds 300
$probe = [ConsoleWindowProbe]::new()
$hostProcess = $null
$report = $null
try {
    $logPath = Join-Path $directory 'space and 中文.log'
    $hostProcess = Start-TestHost @('--log-file', $logPath) 'tree'
    $reportPath = Join-Path $work 'report.json'
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not (Test-Path -LiteralPath $reportPath)) {
        if ($hostProcess.HasExited) { throw "Host exited before its agent was ready: $($hostProcess.ExitCode)" }
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Agent readiness report timed out.' }
        Start-Sleep -Milliseconds 25
    }
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    if ($report.Console -ne 0) { throw 'Hosted agent has a console window handle.' }
    if (($report.Args | ConvertTo-Json -Compress) -ne (@('serve', '--managed-service', '--log-file', $logPath) | ConvertTo-Json -Compress)) {
        throw 'Agent arguments did not round-trip.'
    }
    foreach ($processId in @($report.PID) + @($report.Children)) {
        if (-not (Get-Process -Id $processId -ErrorAction SilentlyContinue)) { throw 'An expected process was not running.' }
    }
    $controlDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while ($probe.Count -eq 0 -and [DateTime]::UtcNow -lt $controlDeadline) { Start-Sleep -Milliseconds 25 }
    if ($probe.Count -ne 0) { throw 'Observed a new visible console during hosted startup.' }
    $hostProcess.Kill()
    $hostProcess.WaitForExit()
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $remaining = @(@($report.PID) + @($report.Children) | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        if ($remaining.Count -eq 0) { break }
        Start-Sleep -Milliseconds 25
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($remaining.Count -gt 0) { throw 'Job Object did not terminate the full process tree within 5 seconds.' }
    Write-Host 'Host integration passed: exit codes, private error, argument round-trip, no console, child tree cleanup.'
} finally {
    if ($hostProcess -and -not $hostProcess.HasExited) { $hostProcess.Kill($true); $hostProcess.WaitForExit() }
    if ($hostProcess) { $hostProcess.Dispose() }
    $probe.Dispose()
}

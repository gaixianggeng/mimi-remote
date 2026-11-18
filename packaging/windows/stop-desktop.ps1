[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$InstallPath)

$ErrorActionPreference = 'Stop'
$InstallPath = [IO.Path]::GetFullPath($InstallPath)
$images = @(
    (Join-Path $InstallPath 'mimi-remote-tray.exe'),
    (Join-Path $InstallPath 'app\MimiRemote.exe')
)
$session = [Diagnostics.Process]::GetCurrentProcess().SessionId
$desktop = Get-CimInstance Win32_Process -Filter "Name = 'mimi-remote-tray.exe' OR Name = 'MimiRemote.exe'"
foreach ($process in $desktop) {
    if ($process.SessionId -ne $session -or $process.ExecutablePath -notin $images) {
        continue
    }
    $running = Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue
    if (-not $running) { continue }
    try {
        if ($running.Path -eq $process.ExecutablePath) { $running.Kill() }
    } catch [InvalidOperationException] {
        if (-not $running.HasExited) { throw }
    } finally {
        $running.Dispose()
    }
}

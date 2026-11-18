[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$InstallPath)

$ErrorActionPreference = 'Stop'
$InstallPath = [IO.Path]::GetFullPath($InstallPath)
$legacy = Join-Path $InstallPath 'mimi-remote-tray.exe'
$native = Join-Path $InstallPath 'app\MimiRemote.exe'
$images = @($legacy, $native)
$shutdownEventName = 'Local\MimiRemoteNativeShutdown-7D413E71-19C5-4F02-8AFC-437E1B8019FD'
$session = [Diagnostics.Process]::GetCurrentProcess().SessionId
$desktop = Get-CimInstance Win32_Process -Filter "Name = 'mimi-remote-tray.exe' OR Name = 'MimiRemote.exe'"
foreach ($process in $desktop) {
    if ($process.SessionId -ne $session -or $process.ExecutablePath -notin $images) {
        continue
    }
    $running = Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue
    if (-not $running) { continue }
    try {
        if ($running.Path -ne $process.ExecutablePath) { continue }
        if ($running.Path -eq $native) {
            $signal = $null
            if ([Threading.EventWaitHandle]::TryOpenExisting($shutdownEventName, [ref]$signal)) {
                try { [void]$signal.Set() }
                finally { $signal.Dispose() }
            }
        } else {
            # The Go tray handles the close message by removing its notification icon.
            try { & (Join-Path $env:SystemRoot 'System32\taskkill.exe') /PID $process.ProcessId 2>&1 | Out-Null }
            catch { Write-Verbose 'The legacy tray did not accept a close request.' }
        }
        if (-not $running.WaitForExit(2500)) { $running.Kill() }
    } catch [InvalidOperationException] {
        if (-not $running.HasExited) { throw }
    } finally {
        $running.Dispose()
    }
}

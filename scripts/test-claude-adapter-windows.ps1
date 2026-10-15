[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$AdapterPath)
$ErrorActionPreference = 'Stop'
# Windows 上 agentd 用 --tcp-listen 启动 Claude 适配器（#660）。按同样的方式启动编好的可执行文件，
# 确认版本、能力声明与回环 TCP 上的 JSON-RPC 都正常。
$adapter = (Resolve-Path -LiteralPath $AdapterPath).Path
$version = (& $adapter --version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $version -notmatch '^mimi-claude-adapter \d+\.\d+\.\d+$') { throw "Unexpected --version output: $version" }
$capabilities = (& $adapter --capabilities | Out-String) | ConvertFrom-Json
if ($capabilities.methods -notcontains 'turn/start' -or -not $capabilities.claudeCode.minimumVersion) { throw 'The capability declaration is incomplete.' }

$state = Join-Path ([IO.Path]::GetTempPath()) ("mimi-adapter-smoke-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $state 'claude\projects') | Out-Null
$env:MIMI_CLAUDE_ADAPTER_STATE_DIR = Join-Path $state 'adapter'
$env:CLAUDE_CONFIG_DIR = Join-Path $state 'claude'
# 与 agentd 相同：先占一个回环端口，释放后交给适配器绑定。
$reserve = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$reserve.Start()
$port = $reserve.LocalEndpoint.Port
$reserve.Stop()
$process = Start-Process -FilePath $adapter -ArgumentList @('--tcp-listen', "127.0.0.1:$port") -PassThru -NoNewWindow `
    -RedirectStandardError (Join-Path $state 'stderr.log')
$client = $null
try {
    $deadline = (Get-Date).AddSeconds(20)
    while (-not $client) {
        try {
            $client = [System.Net.Sockets.TcpClient]::new('127.0.0.1', $port)
        } catch {
            if ($process.HasExited) { throw "The adapter exited early with code $($process.ExitCode): $(Get-Content -Raw (Join-Path $state 'stderr.log'))" }
            if ((Get-Date) -gt $deadline) { throw 'The adapter did not bind its loopback port.' }
            Start-Sleep -Milliseconds 100
        }
    }
    $stream = $client.GetStream()
    $stream.ReadTimeout = 20000
    $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
    $writer.NewLine = "`n"
    $writer.AutoFlush = $true
    $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false))
    $writer.WriteLine('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"windows-smoke","version":"0"}}}')
    $initialize = $reader.ReadLine() | ConvertFrom-Json
    if ($initialize.id -ne 1 -or $initialize.result.userAgent -notmatch '^mimi-claude-adapter/' -or $initialize.result.platformFamily -ne 'windows') {
        throw "Unexpected initialize response: $($initialize | ConvertTo-Json -Compress -Depth 5)"
    }
    $writer.WriteLine('{"jsonrpc":"2.0","id":2,"method":"thread/list","params":{"limit":1}}')
    $list = $reader.ReadLine() | ConvertFrom-Json
    if ($list.id -ne 2 -or $null -ne $list.error -or $null -eq $list.result.data) {
        throw "Unexpected thread/list response: $($list | ConvertTo-Json -Compress -Depth 5)"
    }
} finally {
    if ($client) { $client.Dispose() }
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Remove-Item -LiteralPath $state -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "Claude adapter Windows smoke test passed: $version on 127.0.0.1:$port"

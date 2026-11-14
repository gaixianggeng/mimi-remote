[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
$dotnet = if ($dotnetCommand) { $dotnetCommand.Source } else { Join-Path $env:ProgramFiles 'dotnet/dotnet.exe' }
$bash = Join-Path $env:ProgramFiles 'Git/bin/bash.exe'
if (-not (Test-Path -LiteralPath $bash)) { $bash = (Get-Command bash -ErrorAction Stop).Source }
$previousArtifacts = $env:MIMI_DOTNET_ARTIFACTS
Push-Location $root
try {
    if (-not $env:MIMI_DOTNET_ARTIFACTS) {
        $env:MIMI_DOTNET_ARTIFACTS = (& $bash -c 'cygpath -w "$(bash ./scripts/development-cache-path.sh dotnet)"').Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve shared .NET cache.' }
    }
    $hostOutput = Join-Path $env:MIMI_DOTNET_ARTIFACTS 'host-validation'
    Push-Location (Join-Path $root 'windows')
    try {
        & $dotnet restore MimiRemote.slnx --locked-mode
        if ($LASTEXITCODE -ne 0) { throw '.NET restore failed.' }
        & $dotnet format MimiRemote.slnx --verify-no-changes --no-restore
        if ($LASTEXITCODE -ne 0) { throw '.NET format failed.' }
        & $dotnet test MimiRemote.slnx -c Release --no-restore
        if ($LASTEXITCODE -ne 0) { throw '.NET tests failed.' }
        & $dotnet publish src/MimiRemote.AgentHost/MimiRemote.AgentHost.csproj -c Release -o $hostOutput --no-restore
        if ($LASTEXITCODE -ne 0) { throw 'Native AOT publish failed.' }
    } finally { Pop-Location }
    & (Join-Path $PSScriptRoot 'test-windows-install.ps1')
    & (Join-Path $PSScriptRoot 'test-windows-agent-host.ps1') -HostPath (Join-Path $hostOutput 'mimi-agent-host.exe')
} finally {
    Pop-Location
    $env:MIMI_DOTNET_ARTIFACTS = $previousArtifacts
}

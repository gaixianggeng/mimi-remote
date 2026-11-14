[CmdletBinding()]
param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$dotnet = Join-Path $env:ProgramFiles 'dotnet/dotnet.exe'
if (-not (Test-Path -LiteralPath $dotnet)) { $dotnet = (Get-Command dotnet -ErrorAction Stop).Source }
$bash = Join-Path $env:ProgramFiles 'Git/bin/bash.exe'
$previousArtifacts = $env:MIMI_DOTNET_ARTIFACTS
Push-Location $root
try {
    if (-not $env:MIMI_DOTNET_ARTIFACTS) {
        $env:MIMI_DOTNET_ARTIFACTS = (& $bash -c 'cygpath -w "$(bash ./scripts/development-cache-path.sh dotnet)"').Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve shared .NET cache.' }
    }
    $output = if ($OutputDirectory) { [IO.Path]::GetFullPath($OutputDirectory) } else { Join-Path $env:MIMI_DOTNET_ARTIFACTS 'previews' }
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    $stage = Join-Path $output ('stage-' + [guid]::NewGuid().ToString('N'))
    $commit = (& git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve source commit.' }
    $dirty = [bool](& git status --porcelain)
    $project = 'src/MimiRemote.App/MimiRemote.App.csproj'
    Push-Location (Join-Path $root 'windows')
    try {
        & $dotnet restore $project -p:Platform=x64 --locked-mode
        if ($LASTEXITCODE -ne 0) { throw 'Native client restore failed.' }
        & $dotnet publish $project -c Release -p:Platform=x64 -p:DebugType=None -p:DebugSymbols=false -o $stage --no-restore
        if ($LASTEXITCODE -ne 0) { throw 'Native client publish failed.' }
        $assets = (& $dotnet msbuild $project -p:Platform=x64 -getProperty:ProjectAssetsFile -verbosity:quiet).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve NuGet assets.' }
    } finally { Pop-Location }
    $goVersion = [regex]::Match((Get-Content -LiteralPath (Join-Path $root 'go.mod') -Raw), '(?m)^go ([0-9.]+)\s*$').Groups[1].Value
    if (-not $goVersion) { throw 'go.mod does not declare a toolchain version.' }
    $previousToolchain = $env:GOTOOLCHAIN
    try {
        $env:GOTOOLCHAIN = "go$goVersion"
        & go build -trimpath -ldflags "-s -w -X main.version=preview-$($commit.Substring(0, 8))" -o (Join-Path $stage 'agentd.exe') ./cmd/agentd
        if ($LASTEXITCODE -ne 0) { throw 'Preview CLI build failed.' }
    } finally { $env:GOTOOLCHAIN = $previousToolchain }
    & (Join-Path $PSScriptRoot 'check-windows-host-subsystem.ps1') -Path (Join-Path $stage 'MimiRemote.exe') -Expected GUI
    & (Join-Path $PSScriptRoot 'check-windows-host-subsystem.ps1') -Path (Join-Path $stage 'agentd.exe') -Expected Console
    & (Join-Path $PSScriptRoot 'copy-windows-client-notices.ps1') -AssetsPath $assets -Destination $stage
    Copy-Item -LiteralPath (Join-Path $root 'packaging/windows/native-preview-readme.txt') -Destination (Join-Path $stage 'README.txt')
    $files = @(Get-ChildItem -LiteralPath $stage -Recurse -File | Where-Object Extension -ne '.pdb')
    $manifest = [ordered]@{ source_commit = $commit; source_dirty = $dirty; preview = $true; signed = $false; files = @($files | ForEach-Object {
        [ordered]@{ path = [IO.Path]::GetRelativePath($stage, $_.FullName).Replace('\', '/'); sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    }) }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'manifest.json') -Encoding utf8
    $archive = Join-Path $output ("mimi-remote-windows-preview-$($commit.Substring(0, 8))-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss')).zip")
    $zip = [IO.Compression.ZipFile]::Open($archive, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in @($files) + @(Get-Item -LiteralPath (Join-Path $stage 'manifest.json'))) {
            $name = [IO.Path]::GetRelativePath($stage, $file.FullName).Replace('\', '/')
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $name, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    } finally { $zip.Dispose() }
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $([IO.Path]::GetFileName($archive))" | Set-Content -LiteralPath ($archive + '.sha256') -Encoding ascii
    # 归档成功后只移除本次创建的暂存目录，先确认绝对路径仍位于输出目录内。
    $resolvedStage = [IO.Path]::GetFullPath($stage)
    if (-not $resolvedStage.StartsWith($output.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Staging path escaped the output directory.' }
    Remove-Item -LiteralPath $resolvedStage -Recurse -Force
    Write-Host "Native preview: $archive"
} finally {
    Pop-Location
    $env:MIMI_DOTNET_ARTIFACTS = $previousArtifacts
}

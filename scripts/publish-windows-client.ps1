[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [ValidatePattern('^$|^v?\d+\.\d+\.\d+([-.][0-9A-Za-z.-]+)?$')]
    [string]$Version,
    [string]$PfxPath,
    [string]$PfxPassword,
    [switch]$AllowUnsignedRelease
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$releaseVersion = if ($Version) { $Version.TrimStart('v') } else { '' }
if ($releaseVersion) {
    if ($PfxPath -and $AllowUnsignedRelease) { throw '-PfxPath and -AllowUnsignedRelease cannot be used together.' }
    if (-not $PfxPath -and -not $AllowUnsignedRelease) {
        throw 'Release client builds require -PfxPath or the explicit -AllowUnsignedRelease switch.'
    }
} else {
    if ($PfxPath -or $AllowUnsignedRelease) {
        throw '-PfxPath and -AllowUnsignedRelease require -Version.'
    }
}
if ($PfxPath -and -not (Test-Path -LiteralPath $PfxPath -PathType Leaf)) { throw "PFX file not found: $PfxPath" }
if ($PfxPath) { $PfxPath = (Resolve-Path -LiteralPath $PfxPath).Path }
if ($PfxPath -and -not $PfxPassword) { $PfxPassword = $env:WINDOWS_SIGN_PFX_PASSWORD }
if ($PfxPath -and -not $PfxPassword) { throw 'PFX password is required via -PfxPassword or WINDOWS_SIGN_PFX_PASSWORD.' }

function Find-Tool([string]$Name, [string[]]$Candidates) {
    $found = Get-Command $Name -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
    foreach ($candidate in $Candidates) { if (Test-Path -LiteralPath $candidate) { return $candidate } }
    throw "Required tool not found: $Name"
}

$dotnet = Find-Tool 'dotnet' @(
    (Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe')
)
$bash = Join-Path $env:ProgramFiles 'Git/bin/bash.exe'
if (-not (Test-Path -LiteralPath $bash)) { $bash = Find-Tool 'bash' @() }
$signtool = $null
$publisher = ''
if ($PfxPath) {
    $sdkSignTools = @(
        Get-ChildItem -Path "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue |
            Sort-Object -Property FullName -Descending |
            ForEach-Object FullName
    )
    $signtool = Find-Tool 'signtool.exe' $sdkSignTools
    $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $PfxPath, $PfxPassword, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $publisher = [BitConverter]::ToString($sha.ComputeHash($certificate.RawData)).Replace('-', '').ToLowerInvariant()
    } finally { $certificate.Dispose(); $sha.Dispose() }
}

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
        $publishArgs = @(
            'publish', $project,
            '-c', 'Release',
            '-p:Platform=x64',
            '-p:DebugType=None',
            '-p:DebugSymbols=false',
            '-o', $stage,
            '--no-restore'
        )
        if ($releaseVersion) {
            $publishArgs += @("-p:Version=$releaseVersion", "-p:InformationalVersion=$releaseVersion")
        }
        if ($publisher) {
            $publishArgs += "-p:MimiReleasePublisherSha256=$publisher"
        }
        & $dotnet @publishArgs
        if ($LASTEXITCODE -ne 0) { throw 'Native client publish failed.' }
        $assets = (& $dotnet msbuild $project -p:Platform=x64 -getProperty:ProjectAssetsFile -verbosity:quiet).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve NuGet assets.' }
    } finally { Pop-Location }
    $goVersion = [regex]::Match((Get-Content -LiteralPath (Join-Path $root 'go.mod') -Raw), '(?m)^go ([0-9.]+)\s*$').Groups[1].Value
    if (-not $goVersion) { throw 'go.mod does not declare a toolchain version.' }
    $agentVersion = if ($releaseVersion) { $releaseVersion } else { "devel-$($commit.Substring(0, 8))" }
    $previousToolchain = $env:GOTOOLCHAIN
    try {
        $env:GOTOOLCHAIN = "go$goVersion"
        & go build -trimpath -ldflags "-s -w -X main.version=$agentVersion" -o (Join-Path $stage 'agentd.exe') ./cmd/agentd
        if ($LASTEXITCODE -ne 0) { throw 'Client companion CLI build failed.' }
    } finally { $env:GOTOOLCHAIN = $previousToolchain }
    $clientExe = Join-Path $stage 'MimiRemote.exe'
    $clientDll = Join-Path $stage 'MimiRemote.dll'
    & (Join-Path $PSScriptRoot 'check-windows-host-subsystem.ps1') -Path $clientExe -Expected GUI
    & (Join-Path $PSScriptRoot 'check-windows-host-subsystem.ps1') -Path (Join-Path $stage 'agentd.exe') -Expected Console
    if ($releaseVersion) {
        $dllVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($clientDll).ProductVersion
        if ($dllVersion -ne $releaseVersion) {
            throw "Published WinUI client version '$dllVersion' does not match release version '$releaseVersion'."
        }
    }
    if ($PfxPath) {
        $dllText = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($clientDll))
        if (-not $dllText.Contains('MimiReleasePublisherSha256') -or -not $dllText.Contains($publisher)) {
            throw 'Published WinUI client assembly is missing the embedded MimiReleasePublisherSha256 publisher pin.'
        }
        foreach ($signTarget in @($clientExe, $clientDll, (Join-Path $stage 'MimiRemote.Core.dll'), (Join-Path $stage 'agentd.exe'))) {
            if (-not (Test-Path -LiteralPath $signTarget -PathType Leaf)) {
                throw "Expected signed client artifact missing: $signTarget"
            }
            & $signtool sign /fd SHA256 /f $PfxPath /p $PfxPassword /tr http://timestamp.digicert.com /td SHA256 $signTarget
            if ($LASTEXITCODE -ne 0) { throw "Client signing failed: $signTarget" }
        }
        & $signtool verify /pa $clientExe
        if ($LASTEXITCODE -ne 0) { throw 'Signed WinUI client signature verification failed.' }
        $clientSig = Get-AuthenticodeSignature -LiteralPath $clientExe
        if ($clientSig.Status -ne 'Valid') {
            throw "Signed WinUI client reported status $($clientSig.Status)."
        }
        $shaCheck = [Security.Cryptography.SHA256]::Create()
        try {
            $signedThumb = [BitConverter]::ToString($shaCheck.ComputeHash($clientSig.SignerCertificate.RawData)).Replace('-', '').ToLowerInvariant()
        } finally { $shaCheck.Dispose() }
        if ($signedThumb -ne $publisher) {
            throw 'Signed WinUI client signer certificate does not match the embedded publisher pin.'
        }
    }
    & (Join-Path $PSScriptRoot 'copy-windows-client-notices.ps1') -AssetsPath $assets -Destination $stage
    Copy-Item -LiteralPath (Join-Path $root 'packaging/windows/native-preview-readme.txt') -Destination (Join-Path $stage 'README.txt')
    $files = @(Get-ChildItem -LiteralPath $stage -Recurse -File | Where-Object Extension -ne '.pdb')
    $signingMode = if (-not $releaseVersion) { 'unsigned-preview' } elseif ($PfxPath) { 'authenticode-pfx' } else { 'unsigned-release' }
    $manifest = [ordered]@{
        source_commit = $commit
        source_dirty = $dirty
        version = if ($releaseVersion) { $releaseVersion } else { '0.0.0-preview' }
        preview = (-not [bool]$releaseVersion)
        signed = [bool]$PfxPath
        signing = $signingMode
        files = @($files | ForEach-Object {
            [ordered]@{ path = [IO.Path]::GetRelativePath($stage, $_.FullName).Replace('\', '/'); sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
        })
    }
    if ($publisher) {
        $manifest['publisher_sha256'] = $publisher
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'manifest.json') -Encoding utf8
    $archiveName = if (-not $releaseVersion) {
        "mimi-remote-windows-preview-$($commit.Substring(0, 8))-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss')).zip"
    } elseif ($PfxPath) {
        "Mimi-Remote-Client-$releaseVersion-win-x64.zip"
    } else {
        "Mimi-Remote-Client-$releaseVersion-win-x64-unsigned.zip"
    }
    $archive = Join-Path $output $archiveName
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
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
    Write-Host "Windows client archive: $archive ($signingMode)"
} finally {
    Pop-Location
    $env:MIMI_DOTNET_ARTIFACTS = $previousArtifacts
}

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^v?\d+\.\d+\.\d+([-.][0-9A-Za-z.-]+)?$')]
    [string]$Version,
    [string]$OutputDirectory,
    [switch]$Snapshot,
    [string]$PfxPath,
    [string]$PfxPassword,
    [switch]$AllowUnsignedRelease,
    [ValidateSet('x86_64-pc-windows-msvc', 'x86_64-pc-windows-gnullvm', 'x86_64-pc-windows-gnu')]
    [string]$RustTarget = 'x86_64-pc-windows-msvc',
    [string]$BridgeBinary
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$OutputDirectory = if ($OutputDirectory) { $OutputDirectory } else { Join-Path $root 'dist-windows' }
$Version = $Version.TrimStart('v')
# 无证书发布必须显式传入开关，避免凭据遗漏时静默降级为未签名安装包。
if ($Snapshot -and $PfxPath) { throw '-Snapshot and -PfxPath cannot be used together.' }
if ($Snapshot -and $AllowUnsignedRelease) { throw '-Snapshot and -AllowUnsignedRelease cannot be used together.' }
if ($PfxPath -and $AllowUnsignedRelease) { throw '-PfxPath and -AllowUnsignedRelease cannot be used together.' }
if (-not $Snapshot -and -not $PfxPath -and -not $AllowUnsignedRelease) {
    throw 'Release builds require -PfxPath or the explicit -AllowUnsignedRelease switch.'
}
if ($BridgeBinary -and -not $Snapshot) { throw '-BridgeBinary is accepted only for local snapshot builds; release builds must compile the bridge from source.' }
if ($BridgeBinary) { $BridgeBinary = (Resolve-Path -LiteralPath $BridgeBinary).Path }
if ($PfxPath -and -not (Test-Path -LiteralPath $PfxPath -PathType Leaf)) { throw "PFX file not found: $PfxPath" }
if ($PfxPath -and -not $PfxPassword) { $PfxPassword = $env:WINDOWS_SIGN_PFX_PASSWORD }
if ($PfxPath -and -not $PfxPassword) { throw 'PFX password is required via -PfxPassword or WINDOWS_SIGN_PFX_PASSWORD.' }

function Find-Tool([string]$Name, [string[]]$Candidates) {
    $found = Get-Command $Name -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
    foreach ($candidate in $Candidates) { if (Test-Path -LiteralPath $candidate) { return $candidate } }
    throw "Required tool not found: $Name"
}

$iscc = Find-Tool 'ISCC.exe' @(
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles(x86)\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
)
$signtool = $null
$signingScript = Join-Path $root 'packaging\windows\sign-authenticode.ps1'
$previousSigningPassword = $env:MIMI_WINDOWS_SIGN_PASSWORD
if ($PfxPath) {
    $sdkSignTools = @(
        Get-ChildItem -Path "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue |
            Sort-Object -Property FullName -Descending |
            ForEach-Object FullName
    )
    $signtool = Find-Tool 'signtool.exe' $sdkSignTools
    if (-not (Test-Path -LiteralPath $signingScript -PathType Leaf)) { throw "Signing wrapper not found: $signingScript" }
}
foreach ($tool in @('go', 'cargo')) { if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Required tool not found: $tool" } }

$output = if ([IO.Path]::IsPathRooted($OutputDirectory)) { [IO.Path]::GetFullPath($OutputDirectory) } else { Join-Path $root $OutputDirectory }
$iconSource = Join-Path $root 'packaging\windows\mimi-remote.ico'
if (-not (Test-Path -LiteralPath $iconSource -PathType Leaf)) { throw "Windows icon not found: $iconSource" }
$work = Join-Path ([IO.Path]::GetTempPath()) ("mimi-windows-" + [Guid]::NewGuid().ToString('N'))
$stage = Join-Path $work 'stage'
New-Item -ItemType Directory -Force -Path $stage, $output | Out-Null
Push-Location $root
try {
    Copy-Item -LiteralPath $iconSource -Destination (Join-Path $stage 'mimi-remote.ico')
    $env:CGO_ENABLED = '0'; $env:GOOS = 'windows'; $env:GOARCH = 'amd64'
    & go build -trimpath -ldflags "-s -w -X main.version=$Version" -o (Join-Path $stage 'agentd.exe') ./cmd/agentd
    if ($LASTEXITCODE -ne 0) { throw 'go build failed.' }
    & go build -trimpath -ldflags "-s -w -H=windowsgui -X main.releaseVersion=$Version" -o (Join-Path $stage 'mimi-remote-tray.exe') ./cmd/mimi-remote-tray
    if ($LASTEXITCODE -ne 0) { throw 'Windows tray build failed.' }
    if ($BridgeBinary) {
        & $BridgeBinary --version
        if ($LASTEXITCODE -ne 0) { throw 'The supplied snapshot bridge binary failed its version probe.' }
        Copy-Item -LiteralPath $BridgeBinary -Destination (Join-Path $stage 'alleycat-claude-bridge.exe')
    } else {
        $previousRustFlags = $env:RUSTFLAGS
        $env:RUSTFLAGS = (($previousRustFlags, '-C target-feature=+crt-static') -join ' ').Trim()
        try {
            & cargo build --locked --release --package alleycat-claude-bridge --target $RustTarget
            if ($LASTEXITCODE -ne 0) { throw 'cargo build failed.' }
        } finally {
            $env:RUSTFLAGS = $previousRustFlags
        }
        Copy-Item -LiteralPath (Join-Path $root "target\$RustTarget\release\alleycat-claude-bridge.exe") -Destination $stage
    }
    if ($PfxPath) {
        foreach ($file in (Get-ChildItem -LiteralPath $stage -Filter '*.exe')) {
            & $signtool sign /fd SHA256 /f $PfxPath /p $PfxPassword /tr http://timestamp.digicert.com /td SHA256 $file.FullName
            if ($LASTEXITCODE -ne 0) { throw "Signing failed: $($file.Name)" }
        }
    }
    $outputBaseName = if ($AllowUnsignedRelease) { "Mimi-Remote-Setup-$Version-unsigned" } else { "Mimi-Remote-Setup-$Version" }
    $isccArgs = @(
        "/DMyAppVersion=$Version",
        "/DSourceDir=$stage",
        "/DOutputDir=$output",
        "/DMyOutputBaseFilename=$outputBaseName"
    )
    if ($PfxPath) {
        $powershell = (Get-Command 'powershell.exe' -ErrorAction Stop).Source
        $signCommand = '$q' + $powershell + '$q -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $q' +
            $signingScript + '$q -SignToolPath $q' + $signtool + '$q -PfxPath $q' + $PfxPath +
            '$q -TargetPath $f'
        $isccArgs += '/DMySignTool=mimi-authenticode'
        $isccArgs += "/Smimi-authenticode=$signCommand"
        $env:MIMI_WINDOWS_SIGN_PASSWORD = $PfxPassword
    }
    $isccArgs += (Join-Path $root 'packaging\windows\mimi-remote.iss')
    & $iscc @isccArgs
    if ($LASTEXITCODE -ne 0) { throw 'Inno Setup compilation failed.' }
    $setup = Join-Path $output "$outputBaseName.exe"
    if (-not (Test-Path -LiteralPath $setup)) { throw "Expected installer was not produced: $setup" }
    $hash = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLowerInvariant()
    $payloadHashes = [ordered]@{}
    foreach ($payloadName in @('agentd.exe', 'alleycat-claude-bridge.exe', 'mimi-remote-tray.exe', 'mimi-remote.ico')) {
        $payloadHashes[$payloadName] = (Get-FileHash -LiteralPath (Join-Path $stage $payloadName) -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $signingMode = if ($Snapshot) { 'unsigned-snapshot' } elseif ($PfxPath) { 'authenticode-pfx' } else { 'unsigned-release' }
    [ordered]@{ product = 'Mimi Remote'; version = $Version; installer = [IO.Path]::GetFileName($setup); sha256 = $hash; signing = $signingMode; rust_target = $RustTarget; rust_crt = 'static'; binaries = @('agentd.exe', 'alleycat-claude-bridge.exe', 'mimi-remote-tray.exe'); assets = @('mimi-remote.ico'); payload_sha256 = $payloadHashes } | ConvertTo-Json | Set-Content -LiteralPath "$setup.metadata.json" -Encoding utf8
    "$hash  $([IO.Path]::GetFileName($setup))" | Set-Content -LiteralPath "$setup.sha256" -Encoding ascii
    Write-Host "Created $setup"
} finally {
    if ($null -eq $previousSigningPassword) {
        Remove-Item Env:MIMI_WINDOWS_SIGN_PASSWORD -ErrorAction SilentlyContinue
    } else {
        $env:MIMI_WINDOWS_SIGN_PASSWORD = $previousSigningPassword
    }
    Pop-Location
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

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
    [string]$BridgeBinary,
    [string]$AdapterBinary
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
if ($AdapterBinary -and -not $Snapshot) { throw '-AdapterBinary is accepted only for local snapshot builds; release builds must compile the adapter from source.' }
if ($AdapterBinary) { $AdapterBinary = (Resolve-Path -LiteralPath $AdapterBinary).Path }
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
$requiredTools = @('go', 'cargo')
if (-not $AdapterBinary) { $requiredTools += 'bun' }
foreach ($tool in $requiredTools) { if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Required tool not found: $tool" } }
# Claude 适配器内嵌 Bun 运行时：版本固定为 bridges/claude-sdk/.bun-version，版本不同产物就不同。
$adapterRoot = Join-Path $root 'bridges\claude-sdk'
$requiredBun = (Get-Content -LiteralPath (Join-Path $adapterRoot '.bun-version') -Raw).Trim()
if (-not $AdapterBinary) {
    $bunVersion = (& bun --version).Trim()
    if ($bunVersion -ne $requiredBun) { throw "The Claude adapter requires Bun $requiredBun, found $bunVersion." }
}

$output = if ([IO.Path]::IsPathRooted($OutputDirectory)) { [IO.Path]::GetFullPath($OutputDirectory) } else { Join-Path $root $OutputDirectory }
$iconSource = Join-Path $root 'packaging\windows\mimi-remote.ico'
if (-not (Test-Path -LiteralPath $iconSource -PathType Leaf)) { throw "Windows icon not found: $iconSource" }
# 安装包随附的 Go、Tailcat、Claude 适配器许可正文以仓库内受门禁校验的这一份为准，不另维护副本。
$noticesSource = Join-Path $root 'THIRD_PARTY_NOTICES.md'
if (-not (Test-Path -LiteralPath $noticesSource -PathType Leaf) -or (Get-Item -LiteralPath $noticesSource).Length -eq 0) {
    throw "Third-party notices not found or empty: $noticesSource"
}
$work = Join-Path ([IO.Path]::GetTempPath()) ("mimi-windows-" + [Guid]::NewGuid().ToString('N'))
$stage = Join-Path $work 'stage'
New-Item -ItemType Directory -Force -Path $stage, $output | Out-Null
Push-Location $root
try {
    Copy-Item -LiteralPath $iconSource -Destination (Join-Path $stage 'mimi-remote.ico')
    Copy-Item -LiteralPath $noticesSource -Destination (Join-Path $stage 'THIRD_PARTY_NOTICES.md')
    $env:CGO_ENABLED = '0'; $env:GOOS = 'windows'; $env:GOARCH = 'amd64'
    & go build -trimpath -ldflags "-s -w -X main.version=$Version" -o (Join-Path $stage 'agentd.exe') ./cmd/agentd
    if ($LASTEXITCODE -ne 0) { throw 'go build failed.' }
    & go build -trimpath -ldflags "-s -w -H=windowsgui -X main.releaseVersion=$Version" -o (Join-Path $stage 'mimi-remote-tray.exe') ./cmd/mimi-remote-tray
    if ($LASTEXITCODE -ne 0) { throw 'Windows tray build failed.' }
    # Tailcat 辅助程序是独立 Go module，要求比根 module 更新的工具链。与 .goreleaser.yml 的
    # linux-tailcat 一样只对它允许自动选择工具链，其余组件的构建环境不变。
    $tailcatPath = Join-Path $stage 'mimi-tailcat-experiment.exe'
    $previousToolchain = $env:GOTOOLCHAIN
    $env:GOTOOLCHAIN = 'auto'
    Push-Location (Join-Path $root 'experiments\tailcat')
    try {
        & go build -trimpath -ldflags "-s -w -X main.version=$Version" -o $tailcatPath ./cmd/mimi-tailcat-experiment
        if ($LASTEXITCODE -ne 0) { throw 'Tailcat helper build failed.' }
    } finally {
        Pop-Location
        if ($null -eq $previousToolchain) { Remove-Item Env:GOTOOLCHAIN -ErrorAction SilentlyContinue } else { $env:GOTOOLCHAIN = $previousToolchain }
    }
    # 辅助程序的版本子命令是 version（不是 --version），必须与安装包版本一致。
    $tailcatVersion = (& $tailcatPath version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $tailcatVersion -ne $Version) { throw "The Tailcat helper reported version '$tailcatVersion', expected $Version." }
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
    # SDK 适配器是 #660 起的默认 Claude 通道；上面的旧 Rust bridge 保留一个版本周期作为回退。
    $adapterPath = Join-Path $stage 'mimi-claude-adapter.exe'
    if ($AdapterBinary) {
        Copy-Item -LiteralPath $AdapterBinary -Destination $adapterPath
    } else {
        Push-Location $adapterRoot
        try {
            & bun install --frozen-lockfile --omit optional
            if ($LASTEXITCODE -ne 0) { throw 'bun install failed for the Claude adapter.' }
            # baseline 运行时不要求 AVX2：Windows 10 仍支持更老的 CPU。
            & bun build --compile --minify --target=bun-windows-x64-baseline src/main.ts --outfile $adapterPath
            if ($LASTEXITCODE -ne 0) { throw 'Claude adapter build failed.' }
        } finally {
            Pop-Location
        }
    }
    & $adapterPath --version
    if ($LASTEXITCODE -ne 0) { throw 'The Claude adapter failed its version probe.' }
    if ($PfxPath) {
        foreach ($file in (Get-ChildItem -LiteralPath $stage -Filter '*.exe')) {
            & $signtool sign /fd SHA256 /f $PfxPath /p $PfxPassword /tr http://timestamp.digicert.com /td SHA256 $file.FullName
            if ($LASTEXITCODE -ne 0) { throw "Signing failed: $($file.Name)" }
        }
        # 签名会改写可执行文件：再跑一次适配器，确认它的内嵌程序没有被破坏。
        & $adapterPath --version
        if ($LASTEXITCODE -ne 0) { throw 'The signed Claude adapter failed its version probe.' }
        $signedTailcatVersion = (& $tailcatPath version | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $signedTailcatVersion -ne $Version) { throw 'The signed Tailcat helper failed its version probe.' }
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
    foreach ($payloadName in @('agentd.exe', 'mimi-claude-adapter.exe', 'alleycat-claude-bridge.exe', 'mimi-remote-tray.exe', 'mimi-tailcat-experiment.exe', 'mimi-remote.ico', 'THIRD_PARTY_NOTICES.md')) {
        $payloadHashes[$payloadName] = (Get-FileHash -LiteralPath (Join-Path $stage $payloadName) -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $signingMode = if ($Snapshot) { 'unsigned-snapshot' } elseif ($PfxPath) { 'authenticode-pfx' } else { 'unsigned-release' }
    [ordered]@{ product = 'Mimi Remote'; version = $Version; installer = [IO.Path]::GetFileName($setup); sha256 = $hash; signing = $signingMode; rust_target = $RustTarget; rust_crt = 'static'; bun_version = $requiredBun; tailcat_version = $tailcatVersion; binaries = @('agentd.exe', 'mimi-claude-adapter.exe', 'alleycat-claude-bridge.exe', 'mimi-remote-tray.exe', 'mimi-tailcat-experiment.exe'); assets = @('mimi-remote.ico', 'THIRD_PARTY_NOTICES.md'); payload_sha256 = $payloadHashes } | ConvertTo-Json | Set-Content -LiteralPath "$setup.metadata.json" -Encoding utf8
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

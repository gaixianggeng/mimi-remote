[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AssetsPath,
    [Parameter(Mandatory = $true)][string]$Destination
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$assets = Get-Content -LiteralPath $AssetsPath -Raw | ConvertFrom-Json -AsHashtable
$licenseRoot = Join-Path $Destination 'licenses'
New-Item -ItemType Directory -Path $licenseRoot -Force | Out-Null
foreach ($name in @('LICENSE', 'NOTICE.md', 'THIRD_PARTY_NOTICES.md')) {
    Copy-Item -LiteralPath (Join-Path $root $name) -Destination $Destination
}
$entries = @()
foreach ($library in $assets.libraries.GetEnumerator() | Sort-Object Key) {
    if ($library.Value.type -ne 'package') { continue }
    $identity = $library.Key.Split('/')
    $packageDirectory = $null
    foreach ($folder in $assets.packageFolders.Keys) {
        $candidate = Join-Path $folder $library.Value.path
        if (Test-Path -LiteralPath $candidate -PathType Container) { $packageDirectory = $candidate; break }
    }
    if (-not $packageDirectory) { throw "NuGet package is missing: $($library.Key)" }
    # SDK 构建工具不随客户端分发，其余已解析依赖保留各自的许可和声明。
    if ($identity[0] -eq 'Microsoft.Windows.SDK.BuildTools') { continue }
    $files = @(Get-ChildItem -LiteralPath $packageDirectory -File | Where-Object {
        $_.Name -match '^(license|notice|third.party.notices|copying)'
    })
    if ($library.Key -eq 'QRCoder/1.6.0') {
        $files = @(Get-Item -LiteralPath (Join-Path $root 'packaging/windows/licenses/QRCoder-1.6.0-LICENSE.txt'))
    }
    if ($identity[0] -in @('H.NotifyIcon', 'H.NotifyIcon.WinUI', 'H.GeneratedIcons.System.Drawing') -and $identity[1] -eq '2.4.1') {
        $files = @(Get-Item -LiteralPath (Join-Path $root 'packaging/windows/licenses/H.NotifyIcon-2.4.1-LICENSE.txt'))
    }
    if ($files.Count -eq 0) { throw "No license text found for $($library.Key); update the notice collector before publishing." }
    $packageName = $library.Key.Replace('/', '-')
    $target = Join-Path $licenseRoot $packageName
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    $names = @()
    foreach ($file in $files) {
        Copy-Item -LiteralPath $file.FullName -Destination $target
        $names += "licenses/$packageName/$($file.Name)"
    }
    $entries += [ordered]@{ package = $identity[0]; version = $identity[1]; notices = $names }
}
$entries | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Destination 'licenses.json') -Encoding utf8
Write-Host "Collected notices for $($entries.Count) resolved NuGet packages."

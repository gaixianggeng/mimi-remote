[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [ValidateSet('GUI', 'Console')]
    [string]$Expected = 'GUI'
)

$ErrorActionPreference = 'Stop'

# 宿主的全部意义是“没有窗口”。WinExe 多数情况下会写成 PE 子系统 2（GUI），
# 但这属于构建工具的实现细节，不能靠假设，发布前必须直接读 PE 头确认。
if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "找不到待检查的可执行文件：$Path"
}

$bytes = [IO.File]::ReadAllBytes($Path)
if ($bytes.Length -lt 512) { throw "文件过小，不是有效的 PE：$Path" }
if ($bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { throw "缺少 MZ 头：$Path" }

$peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
if ($peOffset -le 0 -or $peOffset + 24 -ge $bytes.Length) { throw "e_lfanew 越界：$Path" }
if ($bytes[$peOffset] -ne 0x50 -or $bytes[$peOffset + 1] -ne 0x45) { throw "缺少 PE 签名：$Path" }

$optionalHeader = $peOffset + 24
$magic = [BitConverter]::ToUInt16($bytes, $optionalHeader)
$subsystemOffset = switch ($magic) {
    0x20b { $optionalHeader + 68 }  # PE32+
    0x10b { $optionalHeader + 64 }  # PE32
    default { throw ("未知的可选头 Magic 0x{0:X4}：{1}" -f $magic, $Path) }
}

$subsystem = [BitConverter]::ToUInt16($bytes, $subsystemOffset)
$expectedValue = if ($Expected -eq 'GUI') { 2 } else { 3 }
$name = if ($Expected -eq 'GUI') { 'GUI (2)' } else { 'Console (3)' }

if ($subsystem -ne $expectedValue) {
    throw "PE 子系统不符合预期：$Path 实际为 $subsystem，期望 $name。"
}

Write-Host "PE subsystem OK: $([IO.Path]::GetFileName($Path)) = $name"

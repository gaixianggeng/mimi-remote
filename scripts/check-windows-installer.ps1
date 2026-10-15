[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$InstallerPath, [switch]$RequireSignature)
$ErrorActionPreference = 'Stop'
$installer = (Resolve-Path -LiteralPath $InstallerPath).Path
if ([IO.Path]::GetExtension($installer) -ne '.exe') { throw 'Installer must be a .exe file.' }
$metadataPath = "$installer.metadata.json"
if (-not (Test-Path -LiteralPath $metadataPath)) { throw "Missing metadata: $metadataPath" }
$metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
if ($metadata.installer -ne [IO.Path]::GetFileName($installer)) { throw 'Metadata installer name does not match artifact.' }
foreach ($binary in @('agentd.exe', 'mimi-claude-adapter.exe', 'alleycat-claude-bridge.exe', 'mimi-remote-tray.exe')) {
    if ($metadata.binaries -notcontains $binary) { throw "Metadata does not declare embedded binary: $binary" }
}
if ($metadata.assets -notcontains 'mimi-remote.ico') { throw 'Metadata does not declare the Windows application icon.' }
foreach ($payload in @('agentd.exe', 'mimi-claude-adapter.exe', 'alleycat-claude-bridge.exe', 'mimi-remote-tray.exe', 'mimi-remote.ico')) {
    $payloadHash = $metadata.payload_sha256.$payload
    if ($payloadHash -notmatch '^[0-9a-f]{64}$') { throw "Metadata is missing a valid payload SHA-256: $payload" }
}
if ($metadata.rust_crt -ne 'static') { throw 'Metadata must declare a static Rust CRT.' }
if ($metadata.bun_version -notmatch '^\d+\.\d+\.\d+$') { throw 'Metadata must declare the Bun version the Claude adapter was built with.' }
$actualHash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
if ($metadata.sha256 -ne $actualHash) { throw 'Installer SHA-256 does not match metadata.' }
$checksumPath = "$installer.sha256"
if (-not (Test-Path -LiteralPath $checksumPath)) { throw "Missing SHA-256 file: $checksumPath" }
$checksumLine = (Get-Content -LiteralPath $checksumPath -Raw).Trim()
if ($checksumLine -ne "$actualHash  $([IO.Path]::GetFileName($installer))") { throw 'SHA-256 sidecar does not match installer.' }
$signature = Get-AuthenticodeSignature -LiteralPath $installer
if ($metadata.signing -in @('unsigned-snapshot', 'unsigned-release')) {
    if ($signature.Status -ne 'NotSigned') { throw "Unsigned installer must report NotSigned, got $($signature.Status)." }
} elseif ($metadata.signing -eq 'authenticode-pfx') {
    if ($signature.Status -ne 'Valid') { throw "Signed installer signature is not valid: $($signature.Status)." }
} else { throw "Unknown signing mode: $($metadata.signing)" }
if ($RequireSignature -and $signature.Status -ne 'Valid') { throw 'A valid Authenticode signature is required.' }
Write-Host "Installer validation passed: $installer ($($metadata.signing))"

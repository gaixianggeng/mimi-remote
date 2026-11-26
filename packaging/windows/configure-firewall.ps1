[CmdletBinding()]
param(
    [ValidateSet('Enable', 'Disable', 'Validate', 'ValidateNetwork')]
    [Parameter(Mandatory = $true)][string]$Mode,
    [string]$AgentPath
)

$ErrorActionPreference = 'Stop'
# Elevated invocations are compiled into the signed maintenance image. Only
# the two read-only checks take an installer-supplied path.
function Assert-SignedInstall([string]$Directory, [Collections.Generic.List[IO.FileStream]]$LockedImages) {
    # Only an authenticated agentd for this signed release may receive a rule,
    # even when a standard user approves UAC with another administrator account.
    # Never execute that per-user agent or evaluate any field in the receipt.
    Add-Type -AssemblyName System.Security
    $cms = [System.Security.Cryptography.Pkcs.SignedCms]::new()
    $receiptPath = [IO.Path]::Combine($Directory, 'maintenance-identity.p7m')
    $stream = [IO.File]::Open($receiptPath, 'Open', 'Read', 'Read')
    try {
        if ($stream.Length -gt 131072) { throw 'Unexpected receipt size.' }
        $reader = [IO.BinaryReader]::new($stream)
        $cms.Decode($reader.ReadBytes([int]$stream.Length))
    } finally { $stream.Dispose() }
    if ($cms.Detached -or $cms.SignerInfos.Count -ne 1) { throw 'Invalid maintenance receipt.' }
    $cms.CheckSignature($true)
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $publisher = [BitConverter]::ToString($hash.ComputeHash($cms.SignerInfos[0].Certificate.RawData)).Replace('-', '')
        if ($publisher -ne $env:MIMI_SIGNED_PUBLISHER) { throw 'Unexpected release publisher.' }
    } finally { $hash.Dispose() }
    $receipt = [Text.Encoding]::UTF8.GetString($cms.ContentInfo.Content) | ConvertFrom-Json
    if ($receipt.schema -cne 'mimi.windows.maintenance/v1' -or $receipt.version -cne $env:MIMI_SIGNED_VERSION -or
        $receipt.broker -cne 'agentd.exe' -or $receipt.maintenance -cne 'Mimi-Remote-Maintenance.exe') {
        throw 'Unexpected release identity.'
    }
    foreach ($role in @('broker', 'maintenance')) {
        $path = [IO.Path]::Combine($Directory, $receipt.$role)
        $item = Get-Item -LiteralPath $path
        while ($item) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unexpected reparse point.' }
            if ($item -is [IO.FileInfo]) { $item = $item.Directory } else { $item = $item.Parent }
        }
        $file = [IO.File]::Open($path, 'Open', 'Read', 'Read')
        $LockedImages.Add($file)
        $expected = $receipt.("${role}_sha256")
        if ((Get-FileHash -InputStream $file -Algorithm SHA256).Hash -ne $expected) {
            throw 'Installed image does not match the signed release receipt.'
        }
    }
}

if ($Mode -in @('Enable', 'Disable')) {
    if ($AgentPath) { throw 'Unexpected firewall target.' }
    $source = [Environment]::GetEnvironmentVariable('MIMI_INNO_SOURCE_DIRECTORY')
    # The elevated command owns this process; both handles stay live through
    # rule verification and are released together on exit.
    $lockedImages = [Collections.Generic.List[IO.FileStream]]::new()
    Assert-SignedInstall $source $lockedImages
    $AgentPath = [IO.Path]::Combine($source, 'agentd.exe')
}
$AgentPath = (Resolve-Path -LiteralPath $AgentPath).Path
$label = 'Mimi Remote agentd (Private LAN)'
# Derive the stable rule ID from the canonical installed program path. This
# also identifies the same rule under over-the-shoulder administrator consent.
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $pathHash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($AgentPath.ToUpperInvariant()))
    $ownedName = 'MimiRemote-PrivateLAN-' + [BitConverter]::ToString($pathHash).Replace('-', '')
} finally { $sha.Dispose() }

function Test-PrivateNetwork {
    $routes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' |
        Where-Object { $_.State -eq 'Alive' -and $_.NextHop -ne '0.0.0.0' } |
        ForEach-Object {
            $nic = Get-NetIPInterface -AddressFamily IPv4 -InterfaceIndex $_.InterfaceIndex
            if ($nic.ConnectionState -eq 'Connected') {
                [pscustomobject]@{ Index = $nic.InterfaceIndex; Metric = ([int]$_.RouteMetric + [int]$nic.InterfaceMetric) }
            }
        } | Sort-Object Metric, Index)
    if ($routes.Count -eq 0) { return $false }
    $profiles = @(Get-NetConnectionProfile -InterfaceIndex $routes[0].Index)
    if (-not $profiles.Count -or @($profiles | Where-Object NetworkCategory -ne 'Private').Count) { return $false }
    $connected = @(Get-NetIPInterface -AddressFamily IPv4 -ConnectionState Connected | Select-Object -ExpandProperty InterfaceIndex)
    foreach ($ip in @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object InterfaceIndex -in $connected)) {
        $bytes = [Net.IPAddress]::Parse($ip.IPAddress).GetAddressBytes()
        if ($bytes[0] -eq 10 -or ($bytes[0] -eq 192 -and $bytes[1] -eq 168) -or
            ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31)) {
            $profiles = @(Get-NetConnectionProfile -InterfaceIndex $ip.InterfaceIndex)
            if (-not $profiles.Count -or @($profiles | Where-Object NetworkCategory -ne 'Private').Count) { return $false }
        }
    }
    return $true
}

function Test-ExactRule($Rule) {
    $app = $Rule | Get-NetFirewallApplicationFilter
    $address = $Rule | Get-NetFirewallAddressFilter
    return ($Rule.DisplayName -eq $label -and $Rule.Enabled -eq 'True' -and $Rule.Profile -eq 'Private' -and
        $Rule.Direction -eq 'Inbound' -and $Rule.Action -eq 'Allow' -and $app.Program -eq $AgentPath -and
        @($address.RemoteAddress).Count -eq 1 -and $address.RemoteAddress -contains 'LocalSubnet')
}

# Enumerate the effective store. A provider error must never mean "no rules".
function Get-ProgramAllows {
    Get-NetFirewallApplicationFilter -PolicyStore ActiveStore |
        Where-Object Program -eq $AgentPath |
        ForEach-Object { Get-NetFirewallRule -AssociatedNetFirewallApplicationFilter $_ } |
        Where-Object { $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' }
}

function Test-ValidPolicy {
    $profile = Get-NetFirewallProfile -PolicyStore ActiveStore -Name Private
    $allows = @(Get-ProgramAllows)
    return ($profile.Enabled -eq 'True' -and $profile.DefaultInboundAction -ne 'Allow' -and
        $allows.Count -eq 1 -and (Test-ExactRule $allows[0]))
}

if ($Mode -eq 'ValidateNetwork') {
    if (Test-PrivateNetwork) { exit 0 }
    exit 1
}
if ($Mode -eq 'Validate') {
    if ((Test-PrivateNetwork) -and (Test-ValidPolicy)) { exit 0 }
    exit 1
}

# Only the fixed per-user ID and exact program identify our removable rule.
# Leave old display-name-only rules and other administrators' rules intact.
$owned = @(Get-NetFirewallRule -PolicyStore PersistentStore | Where-Object Name -eq $ownedName)
if ($Mode -eq 'Disable') {
    foreach ($rule in $owned) {
        if ($rule.DisplayName -ne $label -or ($rule | Get-NetFirewallApplicationFilter).Program -ne $AgentPath) {
            throw 'Firewall rule ownership mismatch.'
        }
        $rule | Remove-NetFirewallRule
    }
    if (@(Get-ProgramAllows | Where-Object DisplayName -eq $label).Count) {
        throw 'A legacy rule remains. Review it in Windows Firewall.'
    }
    exit 0
}
if (-not (Test-PrivateNetwork)) { throw 'A trusted Private network is required.' }
if (-not (Test-ValidPolicy)) {
    if ($owned.Count -or @(Get-ProgramAllows).Count) { throw 'Review existing inbound rules for agentd.exe.' }
    New-NetFirewallRule -Name $ownedName -DisplayName $label -Program $AgentPath -Direction Inbound -Action Allow -Enabled True -Profile Private -RemoteAddress LocalSubnet | Out-Null
}
if (-not (Test-PrivateNetwork) -or -not (Test-ValidPolicy)) { throw 'Unable to verify Private LAN policy.' }

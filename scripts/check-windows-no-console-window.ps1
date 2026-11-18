[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$HostPath,
    [switch]$SelfTest
)
# Use an isolated fake agent, never start or stop the user's scheduled task.
& (Join-Path $PSScriptRoot 'test-windows-agent-host.ps1') -HostPath $HostPath -SelfTest:$SelfTest

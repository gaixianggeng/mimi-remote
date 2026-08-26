[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AgentPath,
    [Parameter(Mandatory = $true)][string]$LogPath,
    [string]$TaskName = 'Mimi Remote agentd'
)

$ErrorActionPreference = 'Stop'
$AgentPath = (Resolve-Path -LiteralPath $AgentPath).Path
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name

# agentd removes its PID file before Task Scheduler necessarily transitions the
# previous action from Running to Ready. The task uses IgnoreNew, so registering
# and immediately starting during that window can silently discard the start
# request and leave an upgrade offline. The installer has already stopped and
# unlocked agentd.exe; synchronize the scheduler before replacing the task.
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing -and $existing.State -in @('Running', 'Queued')) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 100
        $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    } while ($existing -and $existing.State -in @('Running', 'Queued') -and [DateTime]::UtcNow -lt $deadline)
    if ($existing -and $existing.State -in @('Running', 'Queued')) {
        throw "Scheduled task did not stop within 10 seconds: $TaskName"
    }
}

$action = New-ScheduledTaskAction -Execute $AgentPath -Argument "serve --managed-service --log-file `"$LogPath`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
$principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description 'Mimi Remote current-user backend' `
    -Force | Out-Null

$registered = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
$registeredSid = ([Security.Principal.NTAccount]$registered.Principal.UserId).
    Translate([Security.Principal.SecurityIdentifier]).Value
$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if ($registeredSid -ne $currentSid -or $registered.Principal.RunLevel -ne 'Limited') {
    throw "Scheduled task principal mismatch: $($registered.Principal.UserId) / $($registered.Principal.RunLevel)"
}

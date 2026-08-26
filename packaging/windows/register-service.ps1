[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AgentPath,
    [Parameter(Mandatory = $true)][string]$ServiceHostPath,
    [Parameter(Mandatory = $true)][string]$LogPath,
    [string]$TaskName = 'Mimi Remote agentd'
)

$ErrorActionPreference = 'Stop'
$AgentPath = (Resolve-Path -LiteralPath $AgentPath).Path
$ServiceHostPath = (Resolve-Path -LiteralPath $ServiceHostPath).Path
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

# agentd.exe 是控制台子系统程序。计划任务直接启动它时，用户从控制面板
# 启动或重启服务会看到终端窗口。改由 windowsgui 托盘程序作为无窗口宿主，
# 同步等待 agentd 退出，让 Task Scheduler 继续准确跟踪服务生命周期。
$serviceArguments = "--service-host --service-agent-path `"$AgentPath`" --service-log-path `"$LogPath`""
$action = New-ScheduledTaskAction -Execute $ServiceHostPath -Argument $serviceArguments
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

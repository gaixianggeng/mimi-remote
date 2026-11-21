[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$HostPath,
    [Parameter(Mandatory = $true)][string]$LogPath,
    [string]$TaskName = 'Mimi Remote agentd'
)

$ErrorActionPreference = 'Stop'
$HostPath = (Resolve-Path -LiteralPath $HostPath).Path
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name

# 任务动作指向 mimi-agent-host.exe（GUI 子系统，不建控制台），由它用
# CREATE_NO_WINDOW 拉起 agentd.exe。不能直接指向 agentd：控制台程序会先被
# 系统分配一个可见窗口，之后才轮到 agentd 自己隐藏，窗口必然闪一下。
if (-not (Test-Path -LiteralPath $HostPath -PathType Leaf)) {
    throw "找不到无窗口宿主：$HostPath"
}

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

$action = New-ScheduledTaskAction -Execute $HostPath -Argument "--log-file `"$LogPath`""
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
# 回读任务动作：如果写入的仍是旧路径，升级后窗口还会弹，但不报错。
$registeredAction = @($registered.Actions)[0]
if ($registeredAction.Execute -ne $HostPath) {
    throw "Scheduled task action mismatch: $($registeredAction.Execute)"
}

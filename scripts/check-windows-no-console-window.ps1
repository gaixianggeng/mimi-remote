[CmdletBinding()]
param(
    [string]$TaskName = 'Mimi Remote agentd',
    [int]$SettleSeconds = 8,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

# #975：不弹终端的运行时验收。只做静态检查无法证明“没有窗口”，
# 这里枚举当前会话的可见控制台窗口，并带阳性对照，避免环境本身看不到窗口时假通过。
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public sealed class ConsoleWindowInfo
{
    public uint ProcessId { get; set; }
    public string ClassName { get; set; }
    public string Title { get; set; }
}

public static class ConsoleWindowProbe
{
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hWnd, StringBuilder buffer, int size);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder buffer, int size);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    public static List<ConsoleWindowInfo> GetVisibleConsoles()
    {
        var result = new List<ConsoleWindowInfo>();
        EnumWindows(delegate (IntPtr hWnd, IntPtr lParam)
        {
            if (!IsWindowVisible(hWnd)) return true;

            var classBuffer = new StringBuilder(256);
            GetClassName(hWnd, classBuffer, classBuffer.Capacity);
            var className = classBuffer.ToString();
            if (className != "ConsoleWindowClass" && className != "CASCADIA_HOSTING_WINDOW_CLASS") return true;

            var titleBuffer = new StringBuilder(256);
            GetWindowText(hWnd, titleBuffer, titleBuffer.Capacity);
            uint processId;
            GetWindowThreadProcessId(hWnd, out processId);

            result.Add(new ConsoleWindowInfo
            {
                ProcessId = processId,
                ClassName = className,
                Title = titleBuffer.ToString(),
            });
            return true;
        }, IntPtr.Zero);
        return result;
    }
}
'@

function Get-VisibleConsoleReport {
    $windows = [ConsoleWindowProbe]::GetVisibleConsoles()
    if ($windows.Count -eq 0) { return '(none)' }
    return (($windows | ForEach-Object { "[$($_.ClassName)|$($_.Title)|pid=$($_.ProcessId)]" }) -join ' ')
}

function Show-Baseline([string]$Label) {
    $windows = [ConsoleWindowProbe]::GetVisibleConsoles()
    Write-Host ("{0}: {1} 个可见控制台窗口 {2}" -f $Label, $windows.Count, (Get-VisibleConsoleReport))
    return $windows.Count
}

# 阳性对照：强制开一个全新控制台。如果这里看不到窗口，说明当前环境
# （会话隔离、无桌面）无法观察窗口，后面的“没有新增”就不能算通过。
Write-Host '=== 阳性对照 ==='
$beforeControl = Show-Baseline '对照前'
$control = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') `
    -ArgumentList '/c', 'ping -n 6 127.0.0.1 >nul' -PassThru
Start-Sleep -Seconds 2
$duringControl = Show-Baseline '对照期间'
$controlDetected = $duringControl -gt $beforeControl
if (-not $controlDetected) {
    Write-Host '阳性对照失败：当前环境看不到新开的控制台窗口，本次结果不可作为验收证据。' -ForegroundColor Yellow
} else {
    Write-Host '阳性对照通过：检测逻辑能发现新开的控制台窗口。' -ForegroundColor Green
}
try { Stop-Process -Id $control.Id -Force -ErrorAction SilentlyContinue } catch { }
Start-Sleep -Seconds 2

if ($SelfTest) {
    if (-not $controlDetected) { exit 1 }
    Write-Host '自检完成。'
    exit 0
}

# 真实链路：由计划任务启动宿主，宿主拉起 agentd。
Write-Host '=== 计划任务启动链路 ==='
$before = Show-Baseline '启动前'
& schtasks.exe /run /tn $TaskName | Out-Null
if ($LASTEXITCODE -ne 0) { throw "无法启动计划任务：$TaskName" }
Start-Sleep -Seconds $SettleSeconds
$during = Show-Baseline '启动后'

$agentd = Get-Process agentd -ErrorAction SilentlyContinue
if (-not $agentd) { Write-Host 'agentd 未运行，检查是否已安装并完成配对。' -ForegroundColor Yellow }

$failed = $false
if (-not $controlDetected) {
    Write-Host 'FAIL: 缺少可信的阳性对照，不能判定通过。' -ForegroundColor Red
    $failed = $true
}
if ($during -gt $before) {
    Write-Host 'FAIL: 服务启动过程中出现新的可见控制台窗口。' -ForegroundColor Red
    $failed = $true
}
if (-not $failed) {
    Write-Host 'PASS: 计划任务启动链路没有出现可见控制台窗口。' -ForegroundColor Green
}

# 还原：验证结束后把任务停下，避免影响用户正在使用的服务。
& schtasks.exe /end /tn $TaskName | Out-Null

if ($failed) { exit 1 }

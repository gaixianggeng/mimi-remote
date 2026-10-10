//go:build windows

package windowslan

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
)

const privateLANFirewallRuleName = "Mimi Remote agentd (Private LAN)"

const policyScript = `
$result = [ordered]@{
    firewall_valid = $false
    profile_private = $false
    interface_alias = ''
    network_category = ''
    unsafe_rules = @()
}

$rules = @(Get-NetFirewallRule -DisplayName $env:MIMI_FIREWALL_RULE_NAME -ErrorAction SilentlyContinue)
if ($rules.Count -eq 1) {
    $rule = $rules[0]
    $application = $rule | Get-NetFirewallApplicationFilter
    $address = $rule | Get-NetFirewallAddressFilter
    $result.firewall_valid = (
        $rule.Enabled -eq 'True' -and
        $rule.Profile -eq 'Private' -and
        $rule.Direction -eq 'Inbound' -and
        $rule.Action -eq 'Allow' -and
        $application.Program -eq $env:MIMI_FIREWALL_AGENT_PATH -and
        $address.RemoteAddress -contains 'LocalSubnet'
    )
}
$unsafeRules = @(
    Get-NetFirewallApplicationFilter -Program $env:MIMI_FIREWALL_AGENT_PATH -ErrorAction SilentlyContinue |
        ForEach-Object {
            Get-NetFirewallRule -AssociatedNetFirewallApplicationFilter $_ -ErrorAction SilentlyContinue
        } |
        Where-Object {
            $_.Enabled -eq 'True' -and
            $_.Direction -eq 'Inbound' -and
            $_.Action -eq 'Allow' -and
            $_.DisplayName -ne $env:MIMI_FIREWALL_RULE_NAME
        }
)
$result.unsafe_rules = @($unsafeRules | ForEach-Object { [string]$_.DisplayName })
if ($unsafeRules.Count -gt 0) {
    $result.firewall_valid = $false
}

$routeCandidates = @(
    Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.State -eq 'Alive' -and $_.NextHop -ne '0.0.0.0' } |
        ForEach-Object {
            $route = $_
            $ipInterface = Get-NetIPInterface -AddressFamily IPv4 -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
            if ($ipInterface -and $ipInterface.ConnectionState -eq 'Connected') {
                [pscustomobject]@{
                    InterfaceIndex = $route.InterfaceIndex
                    Metric = ([int]$route.RouteMetric + [int]$ipInterface.InterfaceMetric)
                }
            }
        } |
        Sort-Object Metric, InterfaceIndex
)
if ($routeCandidates.Count -gt 0) {
    $preferred = $routeCandidates[0]
    $profiles = @(Get-NetConnectionProfile -InterfaceIndex $preferred.InterfaceIndex -ErrorAction SilentlyContinue)
    if ($profiles.Count -gt 0) {
        $profile = $profiles[0]
        $result.interface_alias = [string]$profile.InterfaceAlias
        $result.network_category = [string]$profile.NetworkCategory
        $result.profile_private = ($profile.NetworkCategory -eq 'Private')
    }
}

$result | ConvertTo-Json -Compress
`

func Check(ctx context.Context, agentPath string) (Status, error) {
	resolvedPath, err := exec.LookPath("powershell.exe")
	if err != nil {
		return Status{}, fmt.Errorf("未找到 Windows PowerShell，无法验证局域网安全策略")
	}
	if strings.TrimSpace(agentPath) == "" {
		return Status{}, fmt.Errorf("agentd.exe 路径不能为空")
	}
	cmd := exec.CommandContext(
		ctx,
		resolvedPath,
		"-NoLogo",
		"-NoProfile",
		"-NonInteractive",
		"-Command",
		policyScript,
	)
	cmd.Env = append(
		os.Environ(),
		"MIMI_FIREWALL_RULE_NAME="+privateLANFirewallRuleName,
		"MIMI_FIREWALL_AGENT_PATH="+agentPath,
	)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	output, err := cmd.CombinedOutput()
	if err != nil {
		if ctxErr := ctx.Err(); ctxErr != nil {
			// 超时或取消时 CommandContext 强杀 PowerShell，Windows 上只剩 exit status 1；
			// 保留真实原因，避免被误读成防火墙规则问题。
			return Status{}, fmt.Errorf("检查 Windows 局域网安全策略超时或被取消：%w", ctxErr)
		}
		detail := strings.TrimSpace(string(output))
		if detail != "" {
			return Status{}, fmt.Errorf("检查 Windows 局域网安全策略失败：%s", detail)
		}
		return Status{}, fmt.Errorf("检查 Windows 局域网安全策略失败：%w", err)
	}
	return parseStatus(output)
}

func parseStatus(output []byte) (Status, error) {
	var status Status
	if err := json.Unmarshal(output, &status); err != nil {
		return Status{}, fmt.Errorf("解析 Windows 局域网安全策略失败：%w", err)
	}
	return status, nil
}

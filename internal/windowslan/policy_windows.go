//go:build windows

package windowslan

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/cliinspect"
	"golang.org/x/sys/windows"
)

const privateLANFirewallRuleName = "Mimi Remote agentd (Private LAN)"

const policyScript = `
$ErrorActionPreference = 'Stop'
$result = [ordered]@{
    firewall_valid = $false
    profile_private = $false
    interface_alias = ''
    network_category = ''
    unsafe_rules = @()
}

$rules = @(Get-NetFirewallRule -PolicyStore ActiveStore -DisplayName $env:MIMI_FIREWALL_RULE_NAME -ErrorAction SilentlyContinue |
    Where-Object { ($_ | Get-NetFirewallApplicationFilter).Program -eq $env:MIMI_FIREWALL_AGENT_PATH })
if ($rules.Count -eq 1) {
    $rule = $rules[0]
    $application = $rule | Get-NetFirewallApplicationFilter
    $address = $rule | Get-NetFirewallAddressFilter
    $profile = Get-NetFirewallProfile -PolicyStore ActiveStore -Name Private -ErrorAction Stop
    $result.firewall_valid = (
        $profile.Enabled -eq 'True' -and
        $profile.DefaultInboundAction -ne 'Allow' -and
        $rule.Enabled -eq 'True' -and
        $rule.Profile -eq 'Private' -and
        $rule.Direction -eq 'Inbound' -and
        $rule.Action -eq 'Allow' -and
        $application.Program -eq $env:MIMI_FIREWALL_AGENT_PATH -and
        @($address.RemoteAddress).Count -eq 1 -and
        $address.RemoteAddress -contains 'LocalSubnet'
    )
}
$unsafeRules = @(
    Get-NetFirewallApplicationFilter -PolicyStore ActiveStore -Program $env:MIMI_FIREWALL_AGENT_PATH -ErrorAction SilentlyContinue -ErrorVariable appFilterErrors |
        ForEach-Object {
            Get-NetFirewallRule -AssociatedNetFirewallApplicationFilter $_ -ErrorAction Stop
        } |
        Where-Object {
            $_.Enabled -eq 'True' -and
            $_.Direction -eq 'Inbound' -and
            $_.Action -eq 'Allow' -and
            $_.DisplayName -ne $env:MIMI_FIREWALL_RULE_NAME
        }
)
$result.unsafe_rules = @($unsafeRules | ForEach-Object { [string]$_.DisplayName })
if ($unsafeRules.Count -gt 0 -or $appFilterErrors.Count -gt 0) {
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

# A wildcard bind accepts private IPv4 destinations on every connected NIC.
# A Private default route does not authorize a second Public/unclassified LAN.
if ($result.profile_private) {
    $connected = @(Get-NetIPInterface -AddressFamily IPv4 -ConnectionState Connected -ErrorAction Stop | Select-Object -ExpandProperty InterfaceIndex)
    $lanIndices = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object {
        $octets = [Net.IPAddress]::Parse($_.IPAddress).GetAddressBytes()
        $_.InterfaceIndex -in $connected -and ($octets[0] -eq 10 -or
            ($octets[0] -eq 192 -and $octets[1] -eq 168) -or
            ($octets[0] -eq 172 -and $octets[1] -ge 16 -and $octets[1] -le 31))
    } | Select-Object -ExpandProperty InterfaceIndex -Unique)
    $profiles = @(Get-NetConnectionProfile -ErrorAction Stop)
    foreach ($index in $lanIndices) {
        $nicProfiles = @($profiles | Where-Object { $_.InterfaceIndex -eq $index })
        if ($nicProfiles.Count -eq 0 -or @($nicProfiles | Where-Object { $_.NetworkCategory -ne 'Private' }).Count -gt 0) {
            $result.profile_private = $false
            $result.network_category = 'Unknown'
            foreach ($profile in $nicProfiles) {
                if ($profile.NetworkCategory -ne 'Private') {
                    $result.interface_alias = [string]$profile.InterfaceAlias
                    $result.network_category = [string]$profile.NetworkCategory
                    break
                }
            }
            break
        }
    }
}
$result | ConvertTo-Json -Compress
`

// CanonicalFirewallPath derives the mounted DOS drive-letter path
// (e.g. C:\...\agentd.exe) for a verified executable image so Windows Firewall
// Program filters match even when the process was started via a \\?\Volume{GUID}
// path. Reparse points, directories, devices, and unmounted volumes are rejected.
func CanonicalFirewallPath(agentPath string) (string, error) {
	trimmed := strings.TrimSpace(agentPath)
	if trimmed == "" {
		return "", fmt.Errorf("agentd.exe 路径不能为空")
	}
	utf16Path, err := windows.UTF16PtrFromString(trimmed)
	if err != nil {
		return "", fmt.Errorf("解析 agentd.exe 路径失败：%w", err)
	}
	handle, err := windows.CreateFile(
		utf16Path,
		windows.FILE_READ_ATTRIBUTES,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE,
		nil,
		windows.OPEN_EXISTING,
		windows.FILE_FLAG_OPEN_REPARSE_POINT,
		0,
	)
	if err != nil {
		return "", fmt.Errorf("无法打开已验证的 agentd.exe：%w", err)
	}
	defer windows.CloseHandle(handle)

	var info windows.ByHandleFileInformation
	if err := windows.GetFileInformationByHandle(handle, &info); err != nil {
		return "", fmt.Errorf("无法读取 agentd.exe 文件标识：%w", err)
	}
	if info.FileAttributes&(windows.FILE_ATTRIBUTE_REPARSE_POINT|windows.FILE_ATTRIBUTE_DEVICE|windows.FILE_ATTRIBUTE_DIRECTORY) != 0 {
		return "", errors.New("agentd.exe 路径不能是符号链接、目录或设备")
	}

	const volumeNameDOS = 0x0
	buf := make([]uint16, 4096)
	for {
		n, err := windows.GetFinalPathNameByHandle(handle, &buf[0], uint32(len(buf)), volumeNameDOS)
		if err != nil || n == 0 {
			return "", fmt.Errorf("无法解析 agentd.exe 的规范卷路径：%w", err)
		}
		if int(n) < len(buf) {
			resolved := stripExtendedDrivePrefix(windows.UTF16ToString(buf[:n]))
			if !isDriveLetterPath(resolved) {
				return "", errors.New("agentd.exe 所在卷缺少规范盘符路径")
			}
			return filepath.Clean(resolved), nil
		}
		if n > 32768 {
			return "", errors.New("agentd.exe 规范路径超出长度上限")
		}
		buf = make([]uint16, n+1)
	}
}

func stripExtendedDrivePrefix(path string) string {
	if strings.HasPrefix(path, `\\?\`) {
		candidate := path[4:]
		if isDriveLetterPath(candidate) {
			return candidate
		}
	}
	return path
}

func isDriveLetterPath(path string) bool {
	if len(path) < 3 || path[1] != ':' || path[2] != '\\' {
		return false
	}
	drive := path[0]
	return (drive >= 'A' && drive <= 'Z') || (drive >= 'a' && drive <= 'z')
}

func Check(ctx context.Context, agentPath string) (Status, error) {
	resolvedPath, err := systemPowerShell()
	if err != nil {
		return Status{}, fmt.Errorf("未找到 Windows PowerShell，无法验证局域网安全策略")
	}
	agentPath = strings.TrimSpace(agentPath)
	if agentPath == "" {
		return Status{}, fmt.Errorf("agentd.exe 路径不能为空")
	}
	if strings.HasPrefix(agentPath, `\\?\`) {
		canonical, err := CanonicalFirewallPath(agentPath)
		if err != nil {
			return Status{}, err
		}
		agentPath = canonical
	}
	output, diagnostic, err := cliinspect.Output(ctx, func() (*exec.Cmd, error) {
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
		return cmd, nil
	}, 64<<10)
	if err != nil {
		if ctxErr := ctx.Err(); ctxErr != nil {
			// 超时或取消时 CommandContext 强杀 PowerShell，Windows 上只剩 exit status 1；
			// 保留真实原因，避免被误读成防火墙规则问题。
			return Status{}, fmt.Errorf("检查 Windows 局域网安全策略超时或被取消：%w", ctxErr)
		}
		detail := strings.TrimSpace(string(diagnostic))
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

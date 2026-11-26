//go:build windows

package windowslan

import (
	"context"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

// Execute the production PowerShell expression against synthetic cmdlet
// results. No real network, firewall rule, profile or scheduler is touched.
func TestWindowsLANPolicyEvaluatesMixedProfilesAndRuleScope(t *testing.T) {
	const mocks = `
function Get-NetFirewallRule {
    param($DisplayName,$AssociatedNetFirewallApplicationFilter)
    $rule=[pscustomobject]@{DisplayName=$env:MIMI_FIREWALL_RULE_NAME;Enabled='True';Profile='Private';Direction='Inbound';Action='Allow';Program=$env:MIMI_FIREWALL_AGENT_PATH}
    $rule
    if ($DisplayName -and $case -eq 'other-install') {
        [pscustomobject]@{DisplayName=$rule.DisplayName;Enabled='True';Profile='Private';Direction='Inbound';Action='Allow';Program='other-install.exe'}
    }
    if ($DisplayName -and $case -eq 'same-program') { $rule }
    if ($AssociatedNetFirewallApplicationFilter -and $case -eq 'unsafe') {
        [pscustomobject]@{DisplayName='extra';Enabled='True';Profile='Any';Direction='Inbound';Action='Allow'}
    }
}
function Get-NetFirewallApplicationFilter {
    $rules = @($input)
    if ($rules.Count) { $rules | Select-Object Program }
    else { [pscustomobject]@{Program=$env:MIMI_FIREWALL_AGENT_PATH} }
}
function Get-NetFirewallAddressFilter {
    $scope=@('LocalSubnet')
    if ($case -eq 'wide') { $scope += 'Any' }
    [pscustomobject]@{RemoteAddress=$scope}
}
function Get-NetFirewallProfile { [pscustomobject]@{Enabled='True';DefaultInboundAction='Block'} }
function Get-NetRoute { [pscustomobject]@{State='Alive';NextHop='192.168.50.1';InterfaceIndex=1;RouteMetric=1} }
function Get-NetIPInterface {
    param($ConnectionState,$InterfaceIndex,$AddressFamily)
    [pscustomobject]@{InterfaceIndex=1;ConnectionState='Connected';InterfaceMetric=1}
    if ($ConnectionState) { [pscustomobject]@{InterfaceIndex=2;ConnectionState='Connected';InterfaceMetric=2} }
}
function Get-NetIPAddress {
    [pscustomobject]@{InterfaceIndex=1;IPAddress='192.168.50.2'}
    [pscustomobject]@{InterfaceIndex=2;IPAddress='10.3.1.2'}
}
function Get-NetConnectionProfile {
    param($InterfaceIndex)
    $category='Private'
    if ($case -eq 'public') { $category='Public' }
    [pscustomobject]@{InterfaceIndex=1;InterfaceAlias='fixture-1';NetworkCategory=$category}
    if (!$InterfaceIndex -and $case -ne 'unknown') {
        $category='Private'
        if ($case -eq 'mixed') { $category='Public' }
        [pscustomobject]@{InterfaceIndex=2;InterfaceAlias='fixture-2';NetworkCategory=$category}
    }
}
foreach ($case in @('private','public','mixed','unknown','wide','unsafe','other-install','same-program')) {
 & {
`
	shell, err := systemPowerShell()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, shell, "-NoProfile", "-NoLogo", "-NonInteractive", "-Command", mocks+policyScript+"\n}\n}")
	cmd.Env = append(os.Environ(), "MIMI_FIREWALL_RULE_NAME=policy-fixture", "MIMI_FIREWALL_AGENT_PATH=policy-fixture.exe")
	raw, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("fixture evaluation: %v: %s", err, raw)
	}
	rows := strings.Split(strings.TrimSpace(string(raw)), "\n")
	expected := []bool{true, false, false, false, false, false, true, false}
	if len(rows) != len(expected) {
		t.Fatalf("wrong result count: %d", len(rows))
	}
	for i, line := range rows {
		status, err := parseStatus([]byte(line))
		if err != nil || status.Ready() != expected[i] {
			t.Fatalf("fixture %d: %+v (%v)", i, status, err)
		}
	}
}

package systemproxy

import (
	"context"
	"net/url"
	"slices"
	"strings"
	"testing"
)

func installTestRelay(t *testing.T) *Relay {
	t.Helper()
	relay, err := StartRelay(func(context.Context, string, string) (*url.URL, error) { return nil, nil })
	if err != nil {
		t.Fatal(err)
	}
	uninstall := Install(relay)
	t.Cleanup(func() {
		uninstall()
		_ = relay.Close()
	})
	return relay
}

func TestApplyEnvironmentLeavesChildrenUntouchedWithoutRelay(t *testing.T) {
	environment := []string{"PATH=x"}
	if got := ApplyEnvironment(environment); !slices.Equal(got, environment) {
		t.Fatalf("without an installed relay the environment must not change: %v", got)
	}
}

func TestApplyEnvironmentAddsRelayAndLoopbackBypass(t *testing.T) {
	relay := installTestRelay(t)
	got := ApplyEnvironment([]string{"PATH=x"})
	for _, want := range []string{"HTTPS_PROXY=" + relay.URL(), "HTTP_PROXY=" + relay.URL(), "NO_PROXY=localhost,127.0.0.1,::1"} {
		if !slices.Contains(got, want) {
			t.Fatalf("environment %v is missing %q", got, want)
		}
	}
}

func TestApplyEnvironmentRespectsExplicitProxySettings(t *testing.T) {
	installTestRelay(t)
	for _, explicit := range []string{
		"https_proxy=http://corp.example:3128",
		"HTTP_PROXY=http://corp.example:3128",
		"ALL_PROXY=socks5://127.0.0.1:1080",
		"NO_PROXY=*",
		"no_proxy=",
	} {
		environment := []string{"PATH=x", explicit}
		got := ApplyEnvironment(environment)
		if !slices.Equal(got, environment) {
			t.Fatalf("explicit %q must win over the relay, got %v", explicit, got)
		}
	}
}

func TestRelayURLCarriesPerProcessCredentials(t *testing.T) {
	relay := installTestRelay(t)
	parsed, err := url.Parse(relay.URL())
	if err != nil || parsed.Scheme != "http" || parsed.User == nil || !strings.HasPrefix(parsed.Host, "127.0.0.1:") {
		t.Fatalf("relay URL must be loopback with credentials: %q", relay.URL())
	}
	if password, _ := parsed.User.Password(); len(password) < 32 {
		t.Fatalf("relay password is too short: %d", len(password))
	}
}

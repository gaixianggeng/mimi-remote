//go:build windows

package systemproxy

import (
	"context"
	"testing"
)

func TestSystemResolverAlwaysConnectsLoopbackDirectly(t *testing.T) {
	resolve, ok := SystemResolver()
	if !ok {
		t.Fatal("Windows must provide a system proxy resolver")
	}
	for _, target := range []string{"127.0.0.1:4222", "[::1]:8787", "localhost:8787", "app.localhost:80"} {
		proxyURL, err := resolve(context.Background(), "https", target)
		if err != nil || proxyURL != nil {
			t.Fatalf("loopback %s resolved to %v, %v; want direct", target, proxyURL, err)
		}
	}
}

func TestCurrentSettingsReadsWindowsProxyConfiguration(t *testing.T) {
	settings, err := CurrentSettings()
	if err != nil {
		t.Fatalf("reading the current user's proxy settings failed: %v", err)
	}
	switch settings.Mode() {
	case "pac", "static", "direct":
	default:
		t.Fatalf("unexpected proxy mode %q", settings.Mode())
	}
}

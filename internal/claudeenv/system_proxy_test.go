package claudeenv

import (
	"context"
	"net/url"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/systemproxy"
)

func TestBuildUsesSystemProxyRelayOnlyWithoutExplicitProxy(t *testing.T) {
	isolateProxyEnvironment(t)
	relay, err := systemproxy.StartRelay(func(context.Context, string, string) (*url.URL, error) { return nil, nil })
	if err != nil {
		t.Fatal(err)
	}
	uninstall := systemproxy.Install(relay)
	t.Cleanup(func() {
		uninstall()
		_ = relay.Close()
	})

	environment := Build(nil)
	values := environmentMap(environment)
	if values["HTTPS_PROXY"] != relay.URL() || values["NO_PROXY"] != "localhost,127.0.0.1,::1" {
		t.Fatalf("Claude must reach the network through the system proxy relay: %v", values)
	}
	if !HasSupportedProxy(environment) {
		t.Fatal("the relay is an HTTP proxy Claude Code supports")
	}
	if redacted := ProxyValues(environment); len(redacted) == 0 || redacted[0] != relay.URL() {
		t.Fatalf("relay credentials must be redacted at log boundaries: %v", redacted)
	}

	configured := environmentMap(Build(map[string]string{"HTTPS_PROXY": "http://corp.example:3128"}))
	if configured["HTTPS_PROXY"] != "http://corp.example:3128" || configured["HTTP_PROXY"] != "" {
		t.Fatalf("claude.env proxy must win over the relay: %v", configured)
	}
}

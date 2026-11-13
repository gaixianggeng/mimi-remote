package appserver

import (
	"context"
	"net/url"
	"os"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/systemproxy"
)

func TestBuildManagedEnvUsesSystemProxyRelayOnlyWithoutExplicitProxy(t *testing.T) {
	for _, key := range []string{"HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy"} {
		t.Setenv(key, "")
		if err := os.Unsetenv(key); err != nil {
			t.Fatal(err)
		}
	}
	relay, err := systemproxy.StartRelay(func(context.Context, string, string) (*url.URL, error) { return nil, nil })
	if err != nil {
		t.Fatal(err)
	}
	uninstall := systemproxy.Install(relay)
	t.Cleanup(func() {
		uninstall()
		_ = relay.Close()
	})

	env := strings.Join(buildManagedEnv(nil), "\n")
	for _, want := range []string{"HTTPS_PROXY=" + relay.URL(), "HTTP_PROXY=" + relay.URL(), "NO_PROXY=localhost,127.0.0.1,::1"} {
		if !strings.Contains(env, want) {
			t.Fatalf("受管 Codex 必须经系统代理中转联网，缺少 %q", want)
		}
	}
	configured := strings.Join(buildManagedEnv(map[string]string{"HTTPS_PROXY": "http://corp.example:3128"}), "\n")
	if strings.Contains(configured, relay.URL()) || !strings.Contains(configured, "HTTPS_PROXY=http://corp.example:3128") {
		t.Fatal("codex.env 中的代理必须优先于系统代理中转")
	}
}

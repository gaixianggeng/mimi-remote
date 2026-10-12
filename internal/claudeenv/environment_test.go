package claudeenv

import (
	"os"
	"sort"
	"strings"
	"testing"
)

func TestBuildUsesDeterministicProxyAliasPrecedence(t *testing.T) {
	isolateProxyEnvironment(t)
	t.Setenv("HTTPS_PROXY", "https://inherited-upper.example:8443")
	t.Setenv("https_proxy", "https://inherited-lower.example:8443")
	environment := Build(map[string]string{
		"HTTPS_PROXY": "https://configured-upper.example:8443",
		"https_proxy": "https://configured-lower.example:8443",
		"HTTP_PROXY":  "http://configured-upper.example:8080",
		"http_proxy":  "http://configured-lower.example:8080",
		"ALL_PROXY":   "socks5://configured-upper.example:1080",
		"all_proxy":   "socks5://configured-lower.example:1080",
		"NO_PROXY":    "upper.example",
		"no_proxy":    "lower.example",
	})

	proxies := map[string][]string{}
	for _, item := range environment {
		key, value, ok := strings.Cut(item, "=")
		if ok && proxyGroup(key) != nil {
			proxies[strings.ToLower(key)] = append(proxies[strings.ToLower(key)], value)
		}
	}
	want := map[string]string{
		"https_proxy": "https://configured-lower.example:8443",
		"http_proxy":  "http://configured-lower.example:8080",
		"all_proxy":   "socks5://configured-lower.example:1080",
		"no_proxy":    "lower.example",
	}
	if len(proxies) != len(want) {
		t.Fatalf("lowercase configured proxy must win deterministically: %v", proxies)
	}
	for key, value := range want {
		if got := proxies[key]; len(got) != 1 || got[0] != value {
			t.Fatalf("%s precedence mismatch: got=%v want=%q", key, got, value)
		}
	}
}

func TestBuildAllowsConfiguredEmptyProxyToClearInheritedValue(t *testing.T) {
	isolateProxyEnvironment(t)
	t.Setenv("HTTPS_PROXY", "http://inherited.example:8080")
	environment := Build(map[string]string{"https_proxy": ""})
	values := environmentMap(environment)
	if value, ok := values["HTTPS_PROXY"]; !ok || value != "" {
		t.Fatalf("configured empty lowercase proxy should deterministically clear inheritance: %v", values)
	}
	if HasSupportedProxy(environment) {
		t.Fatal("cleared proxy must not be reported as configured")
	}
}

func TestBuildIncludesWindowsProfileAndForcesPermissions(t *testing.T) {
	t.Setenv("USERPROFILE", `C:\Users\mimi`)
	environment := Build(map[string]string{
		"CLAUDE_BRIDGE_BYPASS_PERMISSIONS": "true",
	})
	values := environmentMap(environment)
	if values["USERPROFILE"] != `C:\Users\mimi` {
		t.Fatalf("profile environment must reach probes and runtime: %v", values)
	}
	if values["CLAUDE_BRIDGE_BYPASS_PERMISSIONS"] != "false" {
		t.Fatalf("permission bypass must be forced off: %v", values)
	}
}

func TestBuildDoesNotInheritAnthropicEnvironment(t *testing.T) {
	for _, key := range []string{
		"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL",
	} {
		t.Setenv(key, "inherited-"+strings.ToLower(key))
	}
	const configured = "https://configured.example"
	environment := Build(map[string]string{"ANTHROPIC_BASE_URL": configured})
	for _, item := range environment {
		key, value, _ := strings.Cut(item, "=")
		if !strings.HasPrefix(strings.ToUpper(key), "ANTHROPIC_") {
			continue
		}
		if key != "ANTHROPIC_BASE_URL" || value != configured {
			t.Fatalf("host ANTHROPIC_* must not reach Claude; only claude.env may set them: %q", item)
		}
	}
	if environmentMap(environment)["ANTHROPIC_BASE_URL"] != configured {
		t.Fatalf("configured ANTHROPIC_* from claude.env should still be forwarded: %v", environment)
	}
}

func TestHasSupportedProxyRejectsAllProxyAndSocks(t *testing.T) {
	if HasSupportedProxy([]string{"ALL_PROXY=socks5://proxy.example:1080"}) {
		t.Fatal("ALL_PROXY alone must not claim Claude HTTP proxy readiness")
	}
	if HasSupportedProxy([]string{"HTTPS_PROXY=socks5://proxy.example:1080"}) {
		t.Fatal("SOCKS URL must not claim Claude HTTP proxy readiness")
	}
	if HasSupportedProxy([]string{"HTTPS_PROXY=proxy.example:8080"}) {
		t.Fatal("proxy without an HTTP(S) URL scheme must not claim readiness")
	}
	if !HasSupportedProxy([]string{"HTTPS_PROXY=http://proxy.example:8080"}) {
		t.Fatal("HTTP CONNECT proxy should be accepted")
	}
}

func TestProxyValuesReturnsAliasesForRedaction(t *testing.T) {
	values := ProxyValues([]string{
		"HTTPS_PROXY=http://alice:hunter2@proxy.example:8080",
		"NO_PROXY=localhost,internal.example",
		"PATH=/bin",
	})
	if len(values) != 2 || values[0] != "http://alice:hunter2@proxy.example:8080" {
		t.Fatalf("proxy values should be returned longest-first: %v", values)
	}
}

// isolateProxyEnvironment removes every proxy alias inherited from the shell
// running the tests, so Build only sees proxies the test sets explicitly.
// Build also falls back to mixed-case spellings such as Http_Proxy, so every
// process key that case-insensitively matches a proxy group is removed too.
// t.Setenv registers restoration of the host value before the key is unset.
func isolateProxyEnvironment(t *testing.T) {
	t.Helper()
	keys := map[string]struct{}{}
	for _, aliases := range proxyAliases {
		for _, key := range aliases {
			keys[key] = struct{}{}
		}
	}
	for _, item := range os.Environ() {
		key, _, _ := strings.Cut(item, "=")
		if key != "" && proxyGroup(key) != nil {
			keys[key] = struct{}{}
		}
	}
	sorted := make([]string, 0, len(keys))
	for key := range keys {
		sorted = append(sorted, key)
	}
	sort.Strings(sorted)
	for _, key := range sorted {
		t.Setenv(key, "")
		if err := os.Unsetenv(key); err != nil {
			t.Fatalf("unset %s: %v", key, err)
		}
	}
}

func environmentMap(environment []string) map[string]string {
	values := map[string]string{}
	for _, item := range environment {
		if key, value, ok := strings.Cut(item, "="); ok {
			values[strings.ToUpper(key)] = value
		}
	}
	return values
}

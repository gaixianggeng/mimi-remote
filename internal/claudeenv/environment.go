package claudeenv

import (
	"net/url"
	"os"
	"runtime"
	"sort"
	"strings"
)

const bypassPermissionsKey = "CLAUDE_BRIDGE_BYPASS_PERMISSIONS"

type environmentValue struct {
	key   string
	value string
}

var inheritedKeys = []string{
	"HOME", "PATH", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "TERM",
	"USERPROFILE", "HOMEDRIVE", "HOMEPATH", "APPDATA", "LOCALAPPDATA",
	"TEMP", "TMP", "SYSTEMROOT", "COMSPEC", "PATHEXT", "PROGRAMDATA",
	"NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE", "SSL_CERT_DIR", "CLAUDE_CODE_CERT_STORE",
}

var proxyAliases = [][]string{
	{"https_proxy", "HTTPS_PROXY"},
	{"http_proxy", "HTTP_PROXY"},
	{"all_proxy", "ALL_PROXY"},
	{"no_proxy", "NO_PROXY"},
}

// Build returns the deterministic, restricted environment shared by setup
// probes, the resident bridge, and the Claude child inherited from that bridge.
// Configured values override inherited values. Proxy aliases follow Claude's
// documented lowercase-before-uppercase preference on every platform.
func Build(extra map[string]string) []string {
	processEnvironment := parseEnvironment(os.Environ())
	values := map[string]environmentValue{}
	for _, key := range inheritedKeys {
		if value, ok := lookupEnvironment(processEnvironment, key); ok && value != "" {
			values[environmentKey(key)] = environmentValue{key: key, value: value}
		}
	}

	extraKeys := make([]string, 0, len(extra))
	for key := range extra {
		extraKeys = append(extraKeys, key)
	}
	sort.Strings(extraKeys)
	for _, key := range extraKeys {
		trimmed := strings.TrimSpace(key)
		if trimmed == "" || strings.Contains(trimmed, "=") || proxyGroup(trimmed) != nil {
			continue
		}
		values[environmentKey(trimmed)] = environmentValue{key: trimmed, value: extra[key]}
	}

	for _, aliases := range proxyAliases {
		entry, ok := preferredProxyValue(extra, processEnvironment, aliases)
		if !ok {
			continue
		}
		for _, alias := range aliases {
			delete(values, environmentKey(alias))
		}
		values[environmentKey(entry.key)] = entry
	}

	values[environmentKey(bypassPermissionsKey)] = environmentValue{
		key:   bypassPermissionsKey,
		value: "false",
	}

	ordered := make([]environmentValue, 0, len(values))
	for _, entry := range values {
		ordered = append(ordered, entry)
	}
	sort.Slice(ordered, func(i, j int) bool {
		left := environmentKey(ordered[i].key)
		right := environmentKey(ordered[j].key)
		if left == right {
			return ordered[i].key < ordered[j].key
		}
		return left < right
	})

	result := make([]string, 0, len(ordered))
	for _, entry := range ordered {
		result = append(result, entry.key+"="+entry.value)
	}
	return result
}

// HasSupportedProxy reports whether Claude has a non-empty HTTP(S) proxy.
// ALL_PROXY is still forwarded for child tools, but it is not treated as proof
// that Claude itself can connect; Claude Code does not support SOCKS proxies.
func HasSupportedProxy(environment []string) bool {
	for _, item := range environment {
		key, value, ok := strings.Cut(item, "=")
		if !ok || strings.TrimSpace(value) == "" {
			continue
		}
		if !strings.EqualFold(key, "HTTP_PROXY") && !strings.EqualFold(key, "HTTPS_PROXY") {
			continue
		}
		parsed, err := url.Parse(strings.TrimSpace(value))
		if err != nil || parsed.Scheme == "" {
			continue
		}
		if strings.EqualFold(parsed.Scheme, "http") || strings.EqualFold(parsed.Scheme, "https") {
			return true
		}
	}
	return false
}

// ProxyValues returns non-empty proxy values, longest first, for exact-value
// redaction at log boundaries.
func ProxyValues(environment []string) []string {
	seen := map[string]struct{}{}
	values := make([]string, 0, len(proxyAliases))
	for _, item := range environment {
		key, value, ok := strings.Cut(item, "=")
		if !ok || strings.TrimSpace(value) == "" || proxyGroup(key) == nil {
			continue
		}
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		values = append(values, value)
	}
	sort.Slice(values, func(i, j int) bool { return len(values[i]) > len(values[j]) })
	return values
}

func parseEnvironment(environment []string) map[string]string {
	values := make(map[string]string, len(environment))
	for _, item := range environment {
		if key, value, ok := strings.Cut(item, "="); ok {
			values[key] = value
		}
	}
	return values
}

func lookupEnvironment(environment map[string]string, key string) (string, bool) {
	if value, ok := environment[key]; ok {
		return value, true
	}
	if runtime.GOOS != "windows" {
		return "", false
	}
	for candidate, value := range environment {
		if strings.EqualFold(candidate, key) {
			return value, true
		}
	}
	return "", false
}

func preferredProxyValue(
	extra map[string]string,
	processEnvironment map[string]string,
	aliases []string,
) (environmentValue, bool) {
	if entry, ok := preferredMapValue(extra, aliases); ok {
		return entry, true
	}
	return preferredMapValue(processEnvironment, aliases)
}

func preferredMapValue(values map[string]string, aliases []string) (environmentValue, bool) {
	for _, alias := range aliases {
		if value, ok := values[alias]; ok {
			return environmentValue{key: alias, value: value}, true
		}
	}
	otherKeys := make([]string, 0, 1)
	for key := range values {
		if strings.EqualFold(key, aliases[0]) {
			otherKeys = append(otherKeys, key)
		}
	}
	if len(otherKeys) == 0 {
		return environmentValue{}, false
	}
	sort.Strings(otherKeys)
	key := otherKeys[0]
	return environmentValue{key: key, value: values[key]}, true
}

func proxyGroup(key string) []string {
	for _, aliases := range proxyAliases {
		if strings.EqualFold(key, aliases[0]) {
			return aliases
		}
	}
	return nil
}

func environmentKey(key string) string {
	if runtime.GOOS == "windows" {
		return strings.ToUpper(key)
	}
	return key
}

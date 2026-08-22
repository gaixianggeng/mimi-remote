//go:build !windows

package setup

func claudeSystemProxyConfigured() bool {
	return false
}

func claudeEnvironmentKey(key string) string {
	return key
}

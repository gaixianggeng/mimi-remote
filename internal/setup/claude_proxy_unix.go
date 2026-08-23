//go:build !windows

package setup

func claudeSystemProxyStatus() claudeSystemProxyDetection {
	return claudeSystemProxyDetection{Known: true, Source: "not_applicable"}
}

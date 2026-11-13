package systemproxy

import (
	"strings"
	"sync"
)

// loopbackNoProxy 保证子进程访问本机（agentd、MCP 服务等）不绕到中转。
const loopbackNoProxy = "localhost,127.0.0.1,::1"

var (
	installedMu  sync.RWMutex
	installedURL string
)

// Install 让之后启动的受管子进程使用 relay；返回的函数撤销安装。只在 agentd serve
// 进程内调用，诊断、安装等短命令不安装，子进程环境保持原样。
func Install(relay *Relay) func() {
	installedMu.Lock()
	installedURL = relay.URL()
	installedMu.Unlock()
	return func() {
		installedMu.Lock()
		installedURL = ""
		installedMu.Unlock()
	}
}

// ApplyEnvironment 在子进程环境没有任何代理设置时补上中转地址。用户在 codex.env、
// claude.env 或 agentd 自身环境里设置过 HTTP(S)_PROXY、ALL_PROXY 或 NO_PROXY 时一律
// 尊重，包括用 NO_PROXY=* 明确要求直连。
func ApplyEnvironment(environment []string) []string {
	installedMu.RLock()
	relayURL := installedURL
	installedMu.RUnlock()
	if relayURL == "" || HasProxySetting(environment) {
		return environment
	}
	result := make([]string, 0, len(environment)+3)
	result = append(result, environment...)
	return append(result, "HTTPS_PROXY="+relayURL, "HTTP_PROXY="+relayURL, "NO_PROXY="+loopbackNoProxy)
}

// HasProxySetting 判断环境里是否已有代理相关变量（键名不区分大小写，空值也算显式设置）。
func HasProxySetting(environment []string) bool {
	for _, entry := range environment {
		key, _, ok := strings.Cut(entry, "=")
		if !ok {
			continue
		}
		switch strings.ToUpper(strings.TrimSpace(key)) {
		case "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY":
			return true
		}
	}
	return false
}

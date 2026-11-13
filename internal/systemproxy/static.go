package systemproxy

import (
	"net"
	"net/url"
	"strings"
)

// proxyForList 解析 WinINET / WinHTTP 的代理列表，返回 scheme 对应的上游代理：
//   - "host:port"：所有协议共用；
//   - "http=host:port;https=host:port;socks=host:port"：按协议分别指定；
//   - 有多个候选时取第一个。
//
// 列表里的 HTTP 代理同时承担 HTTPS 的 CONNECT 隧道；只有 socks 项时改用 SOCKS5。
func proxyForList(list string, scheme string) *url.URL {
	var shared, specific, socks string
	for _, entry := range splitProxyTokens(list) {
		key, value, keyed := strings.Cut(entry, "=")
		if !keyed {
			if shared == "" {
				shared = entry
			}
			continue
		}
		switch strings.ToLower(strings.TrimSpace(key)) {
		case strings.ToLower(scheme):
			if specific == "" {
				specific = value
			}
		case "socks":
			if socks == "" {
				socks = value
			}
		}
	}
	switch {
	case specific != "":
		return parseProxyAddress(specific, "http")
	case shared != "":
		return parseProxyAddress(shared, "http")
	case socks != "":
		return parseProxyAddress(socks, "socks5")
	}
	return nil
}

func parseProxyAddress(value string, defaultScheme string) *url.URL {
	value = strings.TrimSpace(value)
	if value == "" {
		return nil
	}
	if !strings.Contains(value, "://") {
		value = defaultScheme + "://" + value
	}
	parsed, err := url.Parse(value)
	if err != nil || parsed.Hostname() == "" {
		return nil
	}
	if parsed.Port() == "" {
		port := "80"
		if strings.HasPrefix(strings.ToLower(parsed.Scheme), "socks") {
			port = "1080"
		}
		parsed.Host = net.JoinHostPort(parsed.Hostname(), port)
	}
	return &url.URL{Scheme: strings.ToLower(parsed.Scheme), User: parsed.User, Host: parsed.Host}
}

// bypassesProxy 按 Windows“不使用代理服务器的地址”的规则判断：分号或空白分隔，
// 支持 * 通配；<local> 表示不含点的主机名。匹配不区分大小写。
func bypassesProxy(bypass string, host string) bool {
	host = strings.TrimSuffix(strings.ToLower(strings.Trim(host, "[]")), ".")
	if host == "" {
		return false
	}
	for _, pattern := range splitProxyTokens(bypass) {
		pattern = strings.ToLower(pattern)
		switch pattern {
		case "<local>":
			if !strings.Contains(host, ".") && net.ParseIP(host) == nil {
				return true
			}
			continue
		case "<-loopback>":
			continue
		}
		if _, rest, ok := strings.Cut(pattern, "://"); ok {
			pattern = rest
		}
		if wildcardMatch(pattern, host) {
			return true
		}
	}
	return false
}

func splitProxyTokens(value string) []string {
	return strings.FieldsFunc(value, func(r rune) bool {
		return r == ';' || r == ',' || r == ' ' || r == '\t' || r == '\r' || r == '\n'
	})
}

// wildcardMatch 只支持 *（匹配任意长度），与 Windows 代理例外列表一致。
func wildcardMatch(pattern string, value string) bool {
	parts := strings.Split(pattern, "*")
	if len(parts) == 1 {
		return pattern == value
	}
	if !strings.HasPrefix(value, parts[0]) {
		return false
	}
	value = value[len(parts[0]):]
	last := parts[len(parts)-1]
	for _, part := range parts[1 : len(parts)-1] {
		index := strings.Index(value, part)
		if index < 0 {
			return false
		}
		value = value[index+len(part):]
	}
	return strings.HasSuffix(value, last)
}

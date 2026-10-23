//go:build windows

package systemproxy

import (
	"context"
	"fmt"
	"net"
	"net/url"
	"strings"
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

const (
	winHTTPAccessTypeNoProxy    = 1
	winHTTPAccessTypeNamedProxy = 3
	winHTTPAutoProxyConfigURL   = 0x00000002
	// 代理软件开关系统代理后，几秒内就应作用到新连接。
	settingsCacheLifetime = 3 * time.Second
	// PAC 下载或执行失败后的回退窗口，避免每个连接都卡在同一个失败上。
	pacFailureBackoff = 30 * time.Second
	pacTimeoutMillis  = 5000
)

var (
	winhttp                                   = windows.NewLazySystemDLL("winhttp.dll")
	procWinHttpGetIEProxyConfigForCurrentUser = winhttp.NewProc("WinHttpGetIEProxyConfigForCurrentUser")
	procWinHttpOpen                           = winhttp.NewProc("WinHttpOpen")
	procWinHttpSetTimeouts                    = winhttp.NewProc("WinHttpSetTimeouts")
	procWinHttpGetProxyForUrl                 = winhttp.NewProc("WinHttpGetProxyForUrl")
	procGlobalFree                            = windows.NewLazySystemDLL("kernel32.dll").NewProc("GlobalFree")
)

type winHTTPCurrentUserIEProxyConfig struct {
	AutoDetect    int32
	AutoConfigURL *uint16
	Proxy         *uint16
	ProxyBypass   *uint16
}

type winHTTPAutoProxyOptions struct {
	Flags                 uint32
	AutoDetectFlags       uint32
	AutoConfigURL         *uint16
	Reserved              uintptr
	ReservedDword         uint32
	AutoLogonIfChallenged int32
}

type winHTTPProxyInfo struct {
	AccessType  uint32
	Proxy       *uint16
	ProxyBypass *uint16
}

// Settings 是当前用户 Windows 系统代理的一份快照，只用于本机判断与诊断，不写日志。
type Settings struct {
	AutoConfigURL string
	Proxy         string
	Bypass        string
}

// Mode 用于诊断展示，不含地址。
func (s Settings) Mode() string {
	switch {
	case s.AutoConfigURL != "":
		return "pac"
	case s.Proxy != "":
		return "static"
	default:
		return "direct"
	}
}

// CurrentSettings 读取当前用户的系统代理设置（Internet 选项 / Windows 设置中的“代理”）。
// “自动检测设置”（WPAD）多见于企业网络且探测可能耗时数秒，这里不使用。
func CurrentSettings() (Settings, error) {
	var config winHTTPCurrentUserIEProxyConfig
	result, _, callErr := procWinHttpGetIEProxyConfigForCurrentUser.Call(uintptr(unsafe.Pointer(&config)))
	defer freeWinHTTPString(config.AutoConfigURL)
	defer freeWinHTTPString(config.Proxy)
	defer freeWinHTTPString(config.ProxyBypass)
	if result == 0 {
		return Settings{}, fmt.Errorf("WinHttpGetIEProxyConfigForCurrentUser：%w", callErr)
	}
	return Settings{
		AutoConfigURL: strings.TrimSpace(windows.UTF16PtrToString(config.AutoConfigURL)),
		Proxy:         strings.TrimSpace(windows.UTF16PtrToString(config.Proxy)),
		Bypass:        strings.TrimSpace(windows.UTF16PtrToString(config.ProxyBypass)),
	}, nil
}

// WinHTTP 返回的字符串按文档要求用 GlobalFree 释放。
func freeWinHTTPString(value *uint16) {
	if value != nil {
		procGlobalFree.Call(uintptr(unsafe.Pointer(value)))
	}
}

type windowsResolver struct {
	mu          sync.Mutex
	settings    Settings
	settingsErr error
	readAt      time.Time
	session     uintptr
	pacFailedAt time.Time
}

// SystemResolver 返回按当前 Windows 系统代理解析上游的 Resolver。
func SystemResolver() (Resolver, bool) {
	resolver := &windowsResolver{}
	return resolver.resolve, true
}

func (r *windowsResolver) resolve(_ context.Context, scheme string, hostport string) (*url.URL, error) {
	host := hostOnly(hostport)
	// 本机地址始终直连，与浏览器对系统代理的处理一致。
	if isLoopbackHost(host) {
		return nil, nil
	}
	settings, err := r.currentSettings()
	if err != nil {
		return nil, err
	}
	if settings.AutoConfigURL != "" {
		if proxyURL, ok := r.fromPAC(settings.AutoConfigURL, scheme, hostport); ok {
			return proxyURL, nil
		}
	}
	if settings.Proxy == "" || bypassesProxy(settings.Bypass, host) {
		return nil, nil
	}
	return proxyForList(settings.Proxy, scheme), nil
}

func hostOnly(hostport string) string {
	if host, _, err := net.SplitHostPort(hostport); err == nil {
		return host
	}
	return strings.Trim(hostport, "[]")
}

func isLoopbackHost(host string) bool {
	host = strings.TrimSuffix(strings.ToLower(strings.TrimSpace(host)), ".")
	if host == "localhost" || strings.HasSuffix(host, ".localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func (r *windowsResolver) currentSettings() (Settings, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.readAt.IsZero() && time.Since(r.readAt) < settingsCacheLifetime {
		return r.settings, r.settingsErr
	}
	r.settings, r.settingsErr = CurrentSettings()
	r.readAt = time.Now()
	return r.settings, r.settingsErr
}

// fromPAC 用 WinHTTP 执行 PAC。ok=false 表示 PAC 不可用，由调用方回退到静态代理。
func (r *windowsResolver) fromPAC(pacURL string, scheme string, hostport string) (*url.URL, bool) {
	r.mu.Lock()
	if !r.pacFailedAt.IsZero() && time.Since(r.pacFailedAt) < pacFailureBackoff {
		r.mu.Unlock()
		return nil, false
	}
	session, err := r.ensureSessionLocked()
	r.mu.Unlock()
	if err != nil {
		return nil, false
	}
	target, err := windows.UTF16PtrFromString(scheme + "://" + hostport + "/")
	if err != nil {
		return nil, false
	}
	configURL, err := windows.UTF16PtrFromString(pacURL)
	if err != nil {
		return nil, false
	}
	options := winHTTPAutoProxyOptions{
		Flags:                 winHTTPAutoProxyConfigURL,
		AutoConfigURL:         configURL,
		AutoLogonIfChallenged: 1,
	}
	var info winHTTPProxyInfo
	result, _, _ := procWinHttpGetProxyForUrl.Call(
		session,
		uintptr(unsafe.Pointer(target)),
		uintptr(unsafe.Pointer(&options)),
		uintptr(unsafe.Pointer(&info)),
	)
	defer freeWinHTTPString(info.Proxy)
	defer freeWinHTTPString(info.ProxyBypass)
	if result == 0 {
		r.mu.Lock()
		r.pacFailedAt = time.Now()
		r.mu.Unlock()
		return nil, false
	}
	if info.AccessType != winHTTPAccessTypeNamedProxy || info.Proxy == nil {
		return nil, true
	}
	return proxyForList(windows.UTF16PtrToString(info.Proxy), scheme), true
}

func (r *windowsResolver) ensureSessionLocked() (uintptr, error) {
	if r.session != 0 {
		return r.session, nil
	}
	agent, _ := windows.UTF16PtrFromString("Mimi Remote agentd")
	session, _, callErr := procWinHttpOpen.Call(uintptr(unsafe.Pointer(agent)), winHTTPAccessTypeNoProxy, 0, 0, 0)
	if session == 0 {
		return 0, fmt.Errorf("WinHttpOpen：%w", callErr)
	}
	// 限制 PAC 下载耗时；设置失败只会让 PAC 更慢，不影响解析，所以不检查结果。
	timeout := uintptr(pacTimeoutMillis)
	procWinHttpSetTimeouts.Call(session, timeout, timeout, timeout, timeout)
	r.session = session
	return session, nil
}

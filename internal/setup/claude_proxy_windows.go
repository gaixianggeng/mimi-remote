package setup

import (
	"errors"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

const (
	winHTTPAccessTypeDefaultProxy   = 0
	winHTTPAccessTypeNoProxy        = 1
	winHTTPAccessTypeNamedProxy     = 3
	winHTTPAccessTypeAutomaticProxy = 4
)

var (
	winHTTPDLL                          = windows.NewLazySystemDLL("winhttp.dll")
	winHTTPGetDefaultProxyConfiguration = winHTTPDLL.NewProc("WinHttpGetDefaultProxyConfiguration")
	kernel32DLL                         = windows.NewLazySystemDLL("kernel32.dll")
	globalFreeProc                      = kernel32DLL.NewProc("GlobalFree")
)

type winHTTPProxyInfo struct {
	AccessType  uint32
	Proxy       *uint16
	ProxyBypass *uint16
}

func claudeSystemProxyStatus() claudeSystemProxyDetection {
	key, err := registry.OpenKey(
		registry.CURRENT_USER,
		`Software\Microsoft\Windows\CurrentVersion\Internet Settings`,
		registry.QUERY_VALUE,
	)
	if err != nil {
		if errors.Is(err, registry.ErrNotExist) {
			return claudeWinHTTPProxyStatus()
		}
		return claudeSystemProxyDetection{Source: "unknown"}
	}
	defer key.Close()

	enabled, _, err := key.GetIntegerValue("ProxyEnable")
	if err != nil && !errors.Is(err, registry.ErrNotExist) {
		return claudeSystemProxyDetection{Source: "unknown"}
	}
	if enabled != 0 {
		server, _, serverErr := key.GetStringValue("ProxyServer")
		if serverErr != nil || strings.TrimSpace(server) == "" {
			return claudeSystemProxyDetection{Source: "unknown"}
		}
		return claudeSystemProxyDetection{Enabled: true, Known: true, Source: "wininet_manual"}
	}

	autoConfigURL, _, autoConfigErr := key.GetStringValue("AutoConfigURL")
	if autoConfigErr != nil && !errors.Is(autoConfigErr, registry.ErrNotExist) {
		return claudeSystemProxyDetection{Source: "unknown"}
	}
	if strings.TrimSpace(autoConfigURL) != "" {
		return claudeSystemProxyDetection{Enabled: true, Known: true, Source: "wininet_pac"}
	}

	autoDetect, _, autoDetectErr := key.GetIntegerValue("AutoDetect")
	if autoDetectErr != nil && !errors.Is(autoDetectErr, registry.ErrNotExist) {
		return claudeSystemProxyDetection{Source: "unknown"}
	}
	if autoDetect != 0 {
		return claudeSystemProxyDetection{Enabled: true, Known: true, Source: "wininet_auto_detect"}
	}
	return claudeWinHTTPProxyStatus()
}

func claudeWinHTTPProxyStatus() claudeSystemProxyDetection {
	if err := winHTTPGetDefaultProxyConfiguration.Find(); err != nil {
		return claudeSystemProxyDetection{Source: "unknown"}
	}
	var info winHTTPProxyInfo
	ok, _, callErr := winHTTPGetDefaultProxyConfiguration.Call(uintptr(unsafe.Pointer(&info)))
	if ok == 0 {
		if errors.Is(callErr, windows.ERROR_FILE_NOT_FOUND) {
			return claudeSystemProxyDetection{Known: true, Source: "none"}
		}
		return claudeSystemProxyDetection{Source: "unknown"}
	}
	defer freeGlobalString(info.Proxy)
	defer freeGlobalString(info.ProxyBypass)

	switch info.AccessType {
	case winHTTPAccessTypeNamedProxy:
		if info.Proxy == nil || strings.TrimSpace(windows.UTF16PtrToString(info.Proxy)) == "" {
			return claudeSystemProxyDetection{Source: "unknown"}
		}
		return claudeSystemProxyDetection{Enabled: true, Known: true, Source: "winhttp_manual"}
	case winHTTPAccessTypeAutomaticProxy:
		return claudeSystemProxyDetection{Enabled: true, Known: true, Source: "winhttp_auto"}
	case winHTTPAccessTypeDefaultProxy, winHTTPAccessTypeNoProxy:
		return claudeSystemProxyDetection{Known: true, Source: "none"}
	default:
		return claudeSystemProxyDetection{Source: "unknown"}
	}
}

func freeGlobalString(value *uint16) {
	if value == nil {
		return
	}
	_, _, _ = globalFreeProc.Call(uintptr(unsafe.Pointer(value)))
}

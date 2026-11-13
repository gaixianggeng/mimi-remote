package systemproxy

import "testing"

func TestProxyForListUsesSharedOrPerSchemeEntries(t *testing.T) {
	for _, item := range []struct {
		list, scheme, want string
	}{
		{"127.0.0.1:10808", "https", "http://127.0.0.1:10808"},
		{"127.0.0.1:10808", "http", "http://127.0.0.1:10808"},
		{"http=127.0.0.1:7890;https=127.0.0.1:7891", "https", "http://127.0.0.1:7891"},
		{"http=127.0.0.1:7890;https=127.0.0.1:7891", "http", "http://127.0.0.1:7890"},
		{"socks=127.0.0.1:1080", "https", "socks5://127.0.0.1:1080"},
		{"proxy.example:8080; backup.example:8080", "https", "http://proxy.example:8080"},
		{"proxy.example", "https", "http://proxy.example:80"},
		{"https=http://proxy.example:3128", "https", "http://proxy.example:3128"},
		{"http=127.0.0.1:7890", "https", ""},
		{"", "https", ""},
	} {
		got := proxyForList(item.list, item.scheme)
		gotText := ""
		if got != nil {
			gotText = got.String()
		}
		if gotText != item.want {
			t.Errorf("proxyForList(%q, %q) = %q, want %q", item.list, item.scheme, gotText, item.want)
		}
	}
}

func TestBypassesProxyFollowsWindowsExceptionList(t *testing.T) {
	bypass := "<local>;*.corp.example;10.*;192.168.1.*;exact.example;<-loopback>"
	for host, want := range map[string]bool{
		"intranet":           true,
		"build.corp.example": true,
		"CORP.EXAMPLE":       false,
		"10.2.3.4":           true,
		"192.168.1.20":       true,
		"192.168.2.20":       false,
		"exact.example":      true,
		"sub.exact.example":  false,
		"api.openai.com":     false,
		"chatgpt.com":        false,
	} {
		if got := bypassesProxy(bypass, host); got != want {
			t.Errorf("bypassesProxy(%q) = %v, want %v", host, got, want)
		}
	}
	if bypassesProxy("", "intranet") {
		t.Fatal("an empty exception list must not bypass anything")
	}
}

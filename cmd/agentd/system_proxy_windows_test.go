//go:build windows

package main

import (
	"strings"
	"testing"
)

func TestStartSystemProxyRelayPropagatesStartupFailure(t *testing.T) {
	stop, err := startSystemProxyRelayWithResolver(nil)
	if err == nil || !strings.Contains(err.Error(), "启动 Windows 系统代理中转") {
		t.Fatalf("missing resolver must fail relay startup explicitly: stop=%v err=%v", stop != nil, err)
	}
	if stop != nil {
		t.Fatal("failed relay startup must not return a cleanup function")
	}
}

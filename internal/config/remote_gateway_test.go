package config

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestRemoteGatewayDefaultsDisabledOnLoopback(t *testing.T) {
	cfg, err := loadRawWithoutProjectDiscovery(nil)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.AppServer.RemoteGateway.Enabled {
		t.Fatal("remote gateway 必须默认关闭")
	}
	if cfg.AppServer.RemoteGateway.Listen != DefaultRemoteGatewayListen() {
		t.Fatalf("unexpected listen: %q", cfg.AppServer.RemoteGateway.Listen)
	}
}

func TestRemoteGatewayValidationRequiresDedicatedLoopbackTokenFile(t *testing.T) {
	base := defaults()
	base.Auth.Token = strings.Repeat("a", 32)
	base.Projects = []ProjectConfig{{ID: "p", Name: "p", Path: t.TempDir()}}
	base.Session.OutputBufferBytes = 1
	base.AppServer.WSTokenFile = filepath.Join(t.TempDir(), "upstream-token")
	base.AppServer.RemoteGateway.Enabled = true

	if err := base.Validate(); err == nil || !strings.Contains(err.Error(), "token_file 不能为空") {
		t.Fatalf("missing token file should fail: %v", err)
	}
	base.AppServer.RemoteGateway.TokenFile = base.AppServer.WSTokenFile
	if err := base.Validate(); err == nil || !strings.Contains(err.Error(), "不能复用") {
		t.Fatalf("shared token file should fail: %v", err)
	}
	base.AppServer.RemoteGateway.TokenFile = filepath.Join(t.TempDir(), "remote-token")
	base.AppServer.RemoteGateway.Listen = "0.0.0.0:8788"
	if err := base.Validate(); err == nil || !strings.Contains(err.Error(), "remote_gateway.listen") {
		t.Fatalf("non-loopback listen should fail: %v", err)
	}
	base.AppServer.RemoteGateway.Listen = "127.0.0.1:8788"
	if err := base.Validate(); err != nil {
		t.Fatalf("valid remote gateway config rejected: %v", err)
	}
}

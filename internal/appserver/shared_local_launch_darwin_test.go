//go:build darwin

package appserver

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestSharedLocalLaunchRequiresAqua(t *testing.T) {
	for _, manager := range []string{"Aqua", "Aqua\n"} {
		if err := validateSharedLocalLaunchManager(manager, nil); err != nil {
			t.Fatal(err)
		}
	}
	for _, manager := range []string{"Background", "LoginWindow", "", "Aqua\nBackground"} {
		if err := validateSharedLocalLaunchManager(manager, nil); err == nil {
			t.Fatalf("must reject %q", manager)
		}
	}
	if err := validateSharedLocalLaunchManager("Aqua", errors.New("failed")); err == nil {
		t.Fatal("must reject failed command")
	}
}

func TestSharedLocalTransportPreservesExistingBackgroundServer(t *testing.T) {
	root := shortSharedLocalCodexHome(t)
	socket := filepath.Join(root, sharedLocalSocketDir, sharedLocalSocketName)
	stop := startSharedLocalTestServerWithSession(t, socket, "Background")
	defer stop()
	transport, err := NewSharedLocalTransport(SharedLocalOptions{Env: map[string]string{"CODEX_HOME": root}})
	if err != nil {
		t.Fatal(err)
	}
	transport.startOnce = func(context.Context, SharedLocalOptions) error {
		t.Fatal("旧 Background 服务存在时不得创建 replacement")
		return nil
	}
	err = transport.EnsureReady(context.Background())
	var sessionError *SharedLocalSessionError
	if !errors.As(err, &sessionError) || sessionError.Kind != "background" {
		t.Fatalf("应返回具体登录会话错误：%v", err)
	}
	if _, err := os.Stat(socket); err != nil {
		t.Fatalf("不得删除旧 socket：%v", err)
	}
}

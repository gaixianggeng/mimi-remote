package pushbridge

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestEnabledManagerWithoutDevicesNeverContactsProvider(t *testing.T) {
	var requests atomic.Int32
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer provider.Close()
	store, err := NewDeviceStore(filepath.Join(t.TempDir(), "devices.json"))
	if err != nil {
		t.Fatal(err)
	}
	manager := NewManager(Options{
		Enabled: config.DefaultPushConfig().Enabled, ProviderURL: provider.URL,
		DeviceStore: store, InstallationID: "test-install",
	})
	defer manager.Close()
	if !manager.Enabled() {
		t.Fatal("默认通知必须已启用，测试才覆盖尚未注册设备的状态")
	}
	assertNoDelivery := func() {
		t.Helper()
		if _, sent := manager.NotifyPending(t.Context(), codexApproval()); sent {
			t.Fatal("没有设备时不能签发审批通知")
		}
		for _, event := range []string{EventTurnCompleted, EventTurnFailed, EventTurnInterrupted} {
			if send := manager.PrepareTurnMessage(TurnMessage{
				Runtime: "codex", ThreadID: "thread", TurnID: event, Event: event,
			}); send != nil {
				send(t.Context())
				t.Error("没有设备时不能创建消息投递")
			}
		}
		manager.Resolve(t.Context(), "codex", "session-1", "req-1")
		manager.ResolveThread(t.Context(), "codex", "session-1", "thread-1")
		if got := requests.Load(); got != 0 {
			t.Fatalf("没有设备时不应联系 Provider，实际请求数=%d", got)
		}
	}
	assertNoDelivery()
	if _, err := store.Register(Device{ID: "device", Ticket: "test-ticket", Platform: "ios", ExpiresAt: time.Now().Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	// 已签发但尚未投递的审批在注销最后一台设备后，也不能发送状态清理通知。
	if _, _, created := manager.PreparePending(codexApproval()); !created {
		t.Fatal("注册设备后应能签发审批")
	}
	if _, _, err := store.Remove("device"); err != nil {
		t.Fatal(err)
	}
	assertNoDelivery()
}

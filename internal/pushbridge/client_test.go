package pushbridge

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestNotifyMapsGoneToDeviceUnregistered(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusGone)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"delivered": false,
			"reason":    "unregistered",
		})
	}))
	t.Cleanup(server.Close)

	err := NewClient(server.URL).Notify(context.Background(), Notification{})
	if !errors.Is(err, ErrDeviceUnregistered) {
		t.Fatalf("Provider 410 必须让 agentd 删除设备，got=%v", err)
	}
}

// 手机把消息提醒换绑到另一台电脑后，旧 Ticket 在 Provider 被撤销；这台电脑
// 收到 ticket_revoked 必须删除设备，而不是之后每次审批都重试同一张死 Ticket。
func TestNotifyMapsRevokedTicketToDeviceUnregistered(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		_ = json.NewEncoder(w).Encode(map[string]any{"error": "ticket_revoked"})
	}))
	t.Cleanup(server.Close)

	err := NewClient(server.URL).Notify(context.Background(), Notification{})
	if !errors.Is(err, ErrDeviceUnregistered) {
		t.Fatalf("Provider ticket_revoked 必须让 agentd 删除设备，got=%v", err)
	}
}

// 其它 403 不代表 Ticket 永久失效，不能据此删除设备。
func TestNotifyKeepsDeviceForOtherForbiddenReasons(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		_ = json.NewEncoder(w).Encode(map[string]any{"error": "forbidden"})
	}))
	t.Cleanup(server.Close)

	err := NewClient(server.URL).Notify(context.Background(), Notification{})
	if err == nil {
		t.Fatal("Provider 403 不能被当成投递成功")
	}
	if errors.Is(err, ErrDeviceUnregistered) {
		t.Fatalf("非 ticket_revoked 的 403 不能让 agentd 删除设备，got=%v", err)
	}
}

func TestNotifyKeepsDeviceForConfigurationRejection(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"delivered":   false,
			"reason":      "TopicDisallowed",
			"apns_status": http.StatusForbidden,
		})
	}))
	t.Cleanup(server.Close)

	err := NewClient(server.URL).Notify(context.Background(), Notification{})
	if err == nil {
		t.Fatal("APNs 配置错误不能被当成投递成功")
	}
	if errors.Is(err, ErrDeviceUnregistered) {
		t.Fatalf("APNs 配置错误不能让 agentd 删除设备，got=%v", err)
	}
}

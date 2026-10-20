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

func TestNotifyLiveActivityResponseMapping(t *testing.T) {
	cases := []struct {
		name         string
		status       int
		body         map[string]any
		wantErr      bool
		unregistered bool
	}{
		{"delivered", http.StatusOK, map[string]any{"delivered": true}, false, false},
		{"coalesced", http.StatusAccepted, map[string]any{"accepted": true, "coalesced": true}, false, false},
		{"apns rejected", http.StatusOK, map[string]any{"delivered": false, "reason": "BadDeviceToken"}, true, false},
		{"token gone", http.StatusGone, map[string]any{"delivered": false, "reason": "unregistered"}, true, true},
		{"ticket revoked", http.StatusForbidden, map[string]any{"error": "ticket_revoked"}, true, true},
		{"kind mismatch", http.StatusBadRequest, map[string]any{"error": "ticket_kind_mismatch"}, true, false},
		{"old provider", http.StatusNotFound, map[string]any{}, true, false},
		{"rate limited", http.StatusTooManyRequests, map[string]any{"error": "rate_limited"}, true, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var path string
			var received map[string]any
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
				path = req.URL.Path
				_ = json.NewDecoder(req.Body).Decode(&received)
				w.WriteHeader(tc.status)
				_ = json.NewEncoder(w).Encode(tc.body)
			}))
			t.Cleanup(server.Close)
			err := NewClient(server.URL).NotifyLiveActivity(context.Background(), LiveActivityNotification{
				Event: LiveActivityEventUpdate, Ticket: "mpt1.1.x",
			})
			if (err != nil) != tc.wantErr || errors.Is(err, ErrDeviceUnregistered) != tc.unregistered {
				t.Fatalf("err=%v，期望 wantErr=%v unregistered=%v", err, tc.wantErr, tc.unregistered)
			}
			if path != "/v1/notify/liveactivity" || received["version"] != float64(1) {
				t.Fatalf("请求路径或版本错误：path=%s body=%v", path, received)
			}
		})
	}
}

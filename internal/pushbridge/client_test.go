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

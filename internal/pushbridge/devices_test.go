package pushbridge

import (
	"path/filepath"
	"testing"
	"time"
)

// 投递失败回报的是发请求时的 Ticket 快照。期间手机已用新 Ticket 重新注册同一设备时，
// 旧 Ticket 的失效回报不能把新注册删掉；只有记录仍是那张 Ticket 才删除并落盘。
func TestDeviceStoreRemoveIfTicketKeepsNewerRegistration(t *testing.T) {
	path := filepath.Join(t.TempDir(), "push-devices.json")
	store, err := NewDeviceStore(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, ticket := range []string{"ticket-old", "ticket-new"} {
		if _, err := store.Register(Device{
			ID: "device-a", Ticket: ticket, ExpiresAt: time.Now().Add(24 * time.Hour),
		}); err != nil {
			t.Fatal(err)
		}
	}

	if _, removed, err := store.RemoveIfTicket("device-a", "ticket-old"); err != nil || removed {
		t.Fatalf("旧 Ticket 的回报不能删除新注册：removed=%v err=%v", removed, err)
	}
	if device, ok := store.Get("device-a"); !ok || device.Ticket != "ticket-new" {
		t.Fatalf("新注册应原样保留：ok=%v device=%+v", ok, device)
	}

	if _, removed, err := store.RemoveIfTicket("device-a", "ticket-new"); err != nil || !removed {
		t.Fatalf("当前 Ticket 失效时应删除：removed=%v err=%v", removed, err)
	}
	reloaded, err := NewDeviceStore(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := reloaded.Get("device-a"); ok {
		t.Fatal("删除必须落盘，重启后不能复活")
	}
	if _, removed, err := reloaded.RemoveIfTicket("device-missing", "ticket"); err != nil || removed {
		t.Fatalf("不存在的设备不应报错也不应删除：removed=%v err=%v", removed, err)
	}
}

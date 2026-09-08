package pushbridge

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"time"
)

func TestTurnMessageDeduplicatesConcurrentTerminalEventsAndCannotApprove(t *testing.T) {
	manager, provider := newTestManager(t, true, "one", "two")
	message := TurnMessage{Runtime: "codex", ThreadID: "thread", ProjectID: "project", TurnID: "turn", Event: EventTurnFailed}
	var wg sync.WaitGroup
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if send := manager.PrepareTurnMessage(message); send != nil {
				send(context.Background())
			}
		}()
	}
	wg.Wait()
	got := provider.events(EventTurnFailed)
	if len(got) != 2 {
		t.Fatalf("want one per device, got %d", len(got))
	}
	message.Event = EventTurnCompleted
	if manager.PrepareTurnMessage(message) != nil {
		t.Fatal("failure followed by completed must not notify twice")
	}
	for _, sent := range got {
		route, ok := manager.MessageRoute(sent.ActionID, sent.DeviceID)
		if !ok || route.ThreadID != "thread" || route.ProjectID != "project" {
			t.Fatal("missing message route")
		}
		if _, ok := manager.Actions().Get(sent.ActionID); ok {
			t.Fatal("message must not acquire approval rights")
		}
		if sent.Kind != "" {
			t.Fatal("message must not contain approval kind")
		}
	}
	if _, ok := manager.MessageRoute(got[0].ActionID, "unknown"); ok {
		t.Fatal("unregistered device can access route")
	}
	manager.Devices().Remove(got[0].DeviceID)
	if _, ok := manager.MessageRoute(got[0].ActionID, got[0].DeviceID); ok {
		t.Fatal("removed device can access route")
	}
}

func TestTurnMessageExpiryCapacityAndDisabledMode(t *testing.T) {
	manager, provider := newTestManager(t, true, "one")
	now := time.Now()
	manager.now = func() time.Time { return now }
	message := TurnMessage{Runtime: "claude", ThreadID: "thread", TurnID: "first", Event: EventTurnCompleted}
	manager.PrepareTurnMessage(message)(context.Background())
	first := provider.events(EventTurnCompleted)[0].ActionID
	now = now.Add(24*time.Hour + time.Second)
	if _, ok := manager.MessageRoute(first, "one"); ok {
		t.Fatal("expired route accepted")
	}
	for i := 0; i < maxMessages+2; i++ {
		message.TurnID = fmt.Sprint(i)
		if manager.PrepareTurnMessage(message) == nil {
			t.Fatal("could not enqueue")
		}
		now = now.Add(time.Second)
	}
	if len(manager.messages) != maxMessages {
		t.Fatalf("unbounded routes: %d", len(manager.messages))
	}
	disabled, _ := newTestManager(t, false, "one")
	if disabled.PrepareTurnMessage(message) != nil {
		t.Fatal("disabled notifications sent")
	}
	message.Event = "unknown"
	if manager.PrepareTurnMessage(message) != nil {
		t.Fatal("unknown event accepted")
	}
}

package httpapi

import (
	"net/http"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

func h03Interaction(eventID string) harnessNativeInteraction {
	return harnessNativeInteraction{
		EventID: eventID, SessionID: "session-a", Generation: 1,
		Event: harnessclient.WaterfallApprovalRequest,
	}
}

func TestHarnessNativeH03DeliveryResultDistinguishesDuplicateFromCapacity(t *testing.T) {
	r := newHarnessNativeInteractionRegistry()
	if got := r.registerDelivery(h03Interaction("e1")); got != harnessNativeDeliveryNew {
		t.Fatalf("first: %v", got)
	}
	if got := r.registerDelivery(h03Interaction("e1")); got != harnessNativeDeliveryDuplicate {
		t.Fatalf("redelivery is not overflow: %v", got)
	}
	for i := 1; i < harnessNativeInteractionPendingMax; i++ {
		if got := r.registerDelivery(h03Interaction(eventIDFor(i))); got != harnessNativeDeliveryNew {
			t.Fatalf("fill %d: %v", i, got)
		}
	}
	if got := r.registerDelivery(h03Interaction("overflow")); got != harnessNativeDeliveryFull {
		t.Fatalf("actual overflow: %v", got)
	}
	if got := r.registerDelivery(h03Interaction("e1")); got != harnessNativeDeliveryDuplicate {
		t.Fatalf("duplicate at capacity must remain duplicate: %v", got)
	}
}

func TestHarnessNativeH03DeliveryCannotChangeIdentity(t *testing.T) {
	for _, field := range []string{"session", "generation", "event"} {
		t.Run(field, func(t *testing.T) {
			r := newHarnessNativeInteractionRegistry()
			original := h03Interaction("e1")
			r.deliver(original)
			changed := original
			switch field {
			case "session":
				changed.SessionID = "session-b"
			case "generation":
				changed.Generation = 2
			case "event":
				changed.Event = harnessclient.WaterfallUserQuestions
			}
			if got := r.registerDelivery(changed); got != harnessNativeDeliveryInvalid {
				t.Fatalf("identity conflict accepted: %v", got)
			}
			pending, _, err := r.claim("e1", 1)
			if err != nil || pending == nil || pending.SessionID != original.SessionID || pending.Event != original.Event {
				t.Fatalf("original identity damaged: %+v / %v", pending, err)
			}
		})
	}
}

func TestHarnessNativeH03ClaimReturnsSnapshot(t *testing.T) {
	r := newHarnessNativeInteractionRegistry()
	r.deliver(h03Interaction("e1"))
	pending, _, err := r.claim("e1", 1)
	if err != nil {
		t.Fatal(err)
	}
	pending.Responding = false
	pending.SessionID = "modified-by-caller"
	_, _, err = r.claim("e1", 1)
	if status, _ := harnessNativePolicyStatus(err); status != http.StatusConflict {
		t.Fatalf("caller received registry's mutable pointer: %v", err)
	}
	r.release("e1")
	again, _, err := r.claim("e1", 1)
	if err != nil || again.SessionID != "session-a" {
		t.Fatalf("snapshot modification leaked: %+v / %v", again, err)
	}
}

func TestHarnessNativeH03CancelBeforeDeliveryCannotRevive(t *testing.T) {
	r := newHarnessNativeInteractionRegistry()
	if r.cancelDelivered("e1") {
		t.Fatal("never-delivered event should not be sent downstream")
	}
	if got := r.registerDelivery(h03Interaction("e1")); got != harnessNativeDeliveryTerminal {
		t.Fatalf("cancelled event revived: %v", got)
	}
	if r.pendingCount() != 0 {
		t.Fatal("cancel-before-delivery left pending record")
	}
}

func TestHarnessNativeH03CancelDeliveredIsIdempotent(t *testing.T) {
	r := newHarnessNativeInteractionRegistry()
	r.deliver(h03Interaction("e1"))
	if !r.cancelDelivered("e1") || r.cancelDelivered("e1") {
		t.Fatal("cancel should withdraw the delivered card exactly once")
	}
	if _, result, err := r.claim("e1", 1); err != nil || result != harnessNativeClaimSettled {
		t.Fatalf("late answer should be settled: %v / %v", result, err)
	}
}

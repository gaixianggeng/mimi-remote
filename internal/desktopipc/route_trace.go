package desktopipc

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"log"
	"strings"
	"sync"
	"time"
)

const desktopRouteTraceHashBytes = 6

const (
	desktopRouteTraceRequested           = "desktop_ipc_route_requested"
	desktopRouteTraceDeferred            = "desktop_ipc_route_deferred"
	desktopRouteTraceOpened              = "desktop_ipc_route_opened"
	desktopRouteTraceFollowingConfirmed  = "desktop_ipc_route_following_confirmed"
	desktopRouteTraceConfirmationTimeout = "desktop_ipc_route_confirmation_timeout"
	desktopRouteTraceExhausted           = "desktop_ipc_route_exhausted"
)

// desktopRouteTraceEntry deliberately has no fields for the route, nonce, or
// error. Those values can contain identifiers or local paths that do not help
// diagnose the activation state machine.
type desktopRouteTraceEntry struct {
	Event      string `json:"event"`
	ThreadHash string `json:"thread_hash"`
	Attempt    int    `json:"attempt,omitempty"`
	Reason     string `json:"reason,omitempty"`
	DurationMS int64  `json:"duration_ms,omitempty"`
}

var desktopRouteTraceSink struct {
	sync.Mutex
	writer io.Writer
}

func desktopRouteTrace(event, threadID string, attempt int, reason string, duration time.Duration) {
	threadID = strings.TrimSpace(threadID)
	if threadID == "" {
		return
	}

	entry := desktopRouteTraceEntry{
		Event:      event,
		ThreadHash: desktopRouteThreadHash(threadID),
		Attempt:    attempt,
		Reason:     reason,
		DurationMS: duration.Milliseconds(),
	}
	payload, err := json.Marshal(entry)
	if err != nil {
		return
	}

	desktopRouteTraceSink.Lock()
	defer desktopRouteTraceSink.Unlock()
	if desktopRouteTraceSink.writer != nil {
		_, _ = desktopRouteTraceSink.writer.Write(payload)
		_, _ = io.WriteString(desktopRouteTraceSink.writer, "\n")
		return
	}
	log.Printf("%s", payload)
}

func desktopRouteThreadHash(threadID string) string {
	digest := sha256.Sum256([]byte(strings.TrimSpace(threadID)))
	return hex.EncodeToString(digest[:desktopRouteTraceHashBytes])
}

// setDesktopRouteTraceWriter is intentionally package-private. It gives tests
// an isolated sink without changing the process-wide standard logger.
func setDesktopRouteTraceWriter(writer io.Writer) func() {
	desktopRouteTraceSink.Lock()
	previous := desktopRouteTraceSink.writer
	desktopRouteTraceSink.writer = writer
	desktopRouteTraceSink.Unlock()
	return func() {
		desktopRouteTraceSink.Lock()
		desktopRouteTraceSink.writer = previous
		desktopRouteTraceSink.Unlock()
	}
}

func desktopRouteDeferredReason(err error) string {
	if err == nil {
		return "desktop_not_ready"
	}
	message := strings.ToLower(err.Error())
	switch {
	case strings.Contains(message, "not running"), strings.Contains(message, "desktop is closed"):
		return "desktop_not_running"
	case strings.Contains(message, "only on macos"):
		return "unsupported_platform"
	case strings.Contains(message, "canceled"), strings.Contains(message, "deadline exceeded"):
		return "activation_canceled"
	default:
		return "route_open_failed"
	}
}

func desktopRouteStateReason(state State) string {
	switch state {
	case StateDisabled:
		return "disabled"
	case StateNotInstalled:
		return "desktop_not_installed"
	case StateDesktopNotRunning:
		return "desktop_not_running"
	case StateConnecting:
		return "connecting"
	case StateUnsupportedBuild:
		return "unsupported_build"
	case StateSocketUnavailable:
		return "socket_unavailable"
	case StateProtocolError:
		return "protocol_error"
	case StateLegacyCleanupRequired:
		return "legacy_cleanup_required"
	default:
		return "activation_not_started"
	}
}

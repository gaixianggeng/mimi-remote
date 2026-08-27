package desktopipc

import (
	"encoding/json"
	"fmt"
)

const (
	FrameHeaderBytes = 4
	MaxFrameBytes    = 64 * 1024 * 1024
)

var methodVersions = map[string]int{
	"initialize":                                             1,
	"client-status-changed":                                  1,
	"thread-stream-state-changed":                            11,
	"thread-stream-following-changed":                        1,
	"thread-stream-following-status-requested":               1,
	"thread-archived":                                        2,
	"thread-unarchived":                                      1,
	"thread-read-state-changed":                              2,
	"thread-queued-followups-changed":                        1,
	"thread-owner-discovery":                                 1,
	"thread-follower-start-turn":                             2,
	"thread-follower-load-complete-history":                  1,
	"thread-follower-update-thread-settings":                 1,
	"thread-follower-compact-thread":                         1,
	"thread-follower-steer-turn":                             1,
	"thread-follower-interrupt-turn":                         4,
	"thread-follower-edit-last-user-turn":                    2,
	"thread-follower-command-approval-decision":              1,
	"thread-follower-file-approval-decision":                 1,
	"thread-follower-permissions-request-approval-response":  1,
	"thread-follower-submit-user-input":                      1,
	"thread-follower-submit-mcp-server-elicitation-response": 1,
	"thread-follower-set-queued-follow-ups-state":            1,
}

func MethodVersion(method string) (int, bool) {
	version, ok := methodVersions[method]
	return version, ok
}

type envelope struct {
	Type              string          `json:"type"`
	RequestID         json.RawMessage `json:"requestId,omitempty"`
	SourceClientID    string          `json:"sourceClientId,omitempty"`
	TargetClientID    string          `json:"targetClientId,omitempty"`
	HandledByClientID string          `json:"handledByClientId,omitempty"`
	Version           int             `json:"version,omitempty"`
	Method            string          `json:"method,omitempty"`
	Params            json.RawMessage `json:"params,omitempty"`
	ResultType        string          `json:"resultType,omitempty"`
	Result            json.RawMessage `json:"result,omitempty"`
	Error             string          `json:"error,omitempty"`
	Response          json.RawMessage `json:"response,omitempty"`
	Request           *envelope       `json:"request,omitempty"`
}

func marshalRequest(requestID, clientID, targetClientID, method string, params any, initializing bool) ([]byte, error) {
	version, ok := MethodVersion(method)
	if !ok {
		return nil, fmt.Errorf("unsupported Desktop IPC method %q", method)
	}
	if initializing {
		clientID = "initializing-client"
	}
	payload := map[string]any{
		"type":           "request",
		"requestId":      requestID,
		"sourceClientId": clientID,
		"version":        version,
		"method":         method,
		"params":         params,
	}
	if targetClientID != "" {
		payload["targetClientId"] = targetClientID
	}
	return json.Marshal(payload)
}

func marshalBroadcast(clientID, method string, params any) ([]byte, error) {
	version, ok := MethodVersion(method)
	if !ok {
		return nil, fmt.Errorf("unsupported Desktop IPC method %q", method)
	}
	return json.Marshal(map[string]any{
		"type":           "broadcast",
		"sourceClientId": clientID,
		"version":        version,
		"method":         method,
		"params":         params,
	})
}

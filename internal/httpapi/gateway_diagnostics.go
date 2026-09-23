package httpapi

import (
	"encoding/json"

	"github.com/gaixianggeng/mimi-remote/internal/diagnosticlog"
)

func recordGatewayLifecycle(connectionID, method string, payload []byte) {
	stage, outcome := "", "received"
	switch method {
	case "turn/started":
		stage = "turn_started"
	case "turn/completed":
		stage, outcome = "turn_completed", "succeeded"
	case "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval", "execCommandApproval", "applyPatchApproval", "item/tool/requestUserInput":
		stage = "approval"
	default:
		return // 流式增量不写日志，也不增加额外解析或状态。
	}
	var frame struct {
		Params struct {
			ThreadID string `json:"threadId"`
			TurnID   string `json:"turnId"`
			Turn     struct {
				ID     string `json:"id"`
				Status string `json:"status"`
			} `json:"turn"`
		} `json:"params"`
	}
	_ = json.Unmarshal(payload, &frame)
	turnID := frame.Params.TurnID
	if turnID == "" {
		turnID = frame.Params.Turn.ID
	}
	if method == "turn/completed" {
		switch frame.Params.Turn.Status {
		case "failed":
			outcome = "failed"
		case "interrupted":
			outcome = "cancelled"
		}
	}
	diagnosticlog.Record(stage, outcome, diagnosticlog.Fields{Reference: diagnosticlog.Reference(connectionID + ":" + frame.Params.ThreadID + ":" + turnID)})
}

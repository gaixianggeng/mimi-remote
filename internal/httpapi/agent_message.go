package httpapi

import (
	"fmt"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/codexhistory"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
	sessionpkg "github.com/gaixianggeng/mimi-remote/internal/session"
)

type agentMessage struct {
	ID              string    `json:"id"`
	SessionID       string    `json:"session_id"`
	ClientMessageID string    `json:"client_message_id,omitempty"`
	TurnID          string    `json:"turn_id,omitempty"`
	ItemID          string    `json:"item_id,omitempty"`
	Role            string    `json:"role"`
	Kind            string    `json:"kind"`
	Content         string    `json:"content"`
	CreatedAt       time.Time `json:"created_at"`
	Revision        int       `json:"revision"`
	SendStatus      string    `json:"send_status"`
}

const submittedMessageMatchWindow = 10 * time.Minute

func userMessageConfirmation(sessionID, clientMessageID, rawInput string, createdAt time.Time) (agentMessage, bool) {
	content, ok := submittedUserContent(rawInput)
	if !ok {
		return agentMessage{}, false
	}
	if createdAt.IsZero() {
		createdAt = time.Now().UTC()
	}
	messageID := fmt.Sprintf("local:%s:%d", sessionID, createdAt.UnixNano())
	if clientMessageID != "" {
		// client: 前缀避免和 Codex rollout 里的原生 message id 撞车，同时让 iOS 能按 client_message_id 合并本地回显。
		messageID = "client:" + clientMessageID
	}
	return agentMessage{
		ID:              messageID,
		SessionID:       sessionID,
		ClientMessageID: clientMessageID,
		Role:            "user",
		Kind:            "message",
		Content:         content,
		CreatedAt:       createdAt,
		Revision:        1,
		SendStatus:      "confirmed",
	}, true
}

func recordSubmittedUserMessage(s *sessionpkg.Session, message agentMessage) {
	if s == nil || message.Role != "user" || message.ClientMessageID == "" || message.Content == "" {
		return
	}
	s.RecordSubmittedMessage(sessionpkg.SubmittedMessage{
		ClientMessageID: message.ClientMessageID,
		Content:         message.Content,
		CreatedAt:       message.CreatedAt,
	})
}

func annotateHistoryMessagesWithSubmittedClientIDs(messages []codexhistory.Message, submitted []sessionpkg.SubmittedMessage) []codexhistory.Message {
	if len(messages) == 0 || len(submitted) == 0 {
		return messages
	}
	annotated := append([]codexhistory.Message(nil), messages...)
	used := make([]bool, len(submitted))
	for index := range annotated {
		message := &annotated[index]
		if message.Role != "user" || strings.TrimSpace(message.Content) == "" {
			continue
		}
		submittedIndex := matchingSubmittedMessageIndex(*message, submitted, used)
		if submittedIndex < 0 {
			continue
		}
		used[submittedIndex] = true
		clientMessageID := submitted[submittedIndex].ClientMessageID
		message.ID = "client:" + clientMessageID
		message.ClientMessageID = clientMessageID
		if message.Revision == 0 {
			message.Revision = 1
		}
		if message.SendStatus == "" {
			message.SendStatus = "confirmed"
		}
	}
	return annotated
}

func matchingSubmittedMessageIndex(message codexhistory.Message, submitted []sessionpkg.SubmittedMessage, used []bool) int {
	for index, candidate := range submitted {
		if used[index] || candidate.Content != message.Content {
			continue
		}
		if message.CreatedAt.IsZero() || candidate.CreatedAt.IsZero() ||
			absDuration(message.CreatedAt.Sub(candidate.CreatedAt)) <= submittedMessageMatchWindow {
			return index
		}
	}
	return -1
}

func agentMessageFromHistory(sessionID string, message codexhistory.Message) (agentMessage, bool) {
	if message.Role != "user" && message.Role != "assistant" {
		return agentMessage{}, false
	}
	content := strings.TrimSpace(message.Content)
	if content == "" {
		return agentMessage{}, false
	}
	createdAt := message.CreatedAt
	if createdAt.IsZero() {
		createdAt = time.Now().UTC()
	}
	id := message.ID
	if id == "" {
		id = fmt.Sprintf("history:%s:%s:%d", sessionID, message.Role, createdAt.UnixNano())
	}
	revision := message.Revision
	if revision == 0 {
		revision = 1
	}
	sendStatus := message.SendStatus
	if sendStatus == "" {
		sendStatus = "confirmed"
	}
	return agentMessage{
		ID:              id,
		SessionID:       sessionID,
		ClientMessageID: message.ClientMessageID,
		Role:            message.Role,
		Kind:            "message",
		Content:         message.Content,
		CreatedAt:       createdAt,
		Revision:        revision,
		SendStatus:      sendStatus,
	}, true
}

func historyThreadIDForSession(registry *projects.Registry, sessionID string, s *sessionpkg.Session) string {
	if s == nil {
		return codexhistory.ThreadIDForSession(sessionID, "")
	}
	snapshot := s.Snapshot()
	if snapshot.HistoryThreadID != "" {
		return snapshot.HistoryThreadID
	}
	// baseline：新会话是 session id 本身，resume 会话是 resume thread。
	baseline := codexhistory.ThreadIDForSession(sessionID, snapshot.ResumeID)
	if registry == nil || snapshot.ProjectID == "" {
		return baseline
	}
	project, ok := registry.Get(snapshot.ProjectID)
	if !ok {
		return baseline
	}
	// 探测“会话开始后新建”的 thread，覆盖两种场景：
	//   1) 新建会话：Codex 启动后才把真实 thread 写进 state.sqlite；
	//   2) resume 会话：Codex 把对话 fork 成了新 thread（旧 resume id 不再写入新消息）。
	// resume 沿用同一 thread 时这里探不到（它在会话开始前就已存在，被 created_at 过滤掉），
	// 直接回退到 baseline，因此不会破坏“resume 继续同一 thread”的既有行为。
	threadID, err := codexhistory.LatestThreadIDForProjectSince(project, snapshot.CreatedAt)
	if err != nil || threadID == "" || threadID == baseline {
		return baseline
	}
	if s.SetHistoryThreadID(threadID) {
		// 发现后记录到运行态 session，后续消息读取都走这个稳定映射。
		s.RecordTrace(sessionpkg.TraceEvent{Type: "history_thread_mapped", Reason: threadID})
	}
	return threadID
}

func recentCodexMessagesForSession(registry *projects.Registry, sessionID string, s *sessionpkg.Session, limit int) ([]codexhistory.Message, error) {
	threadID := historyThreadIDForSession(registry, sessionID, s)
	if threadID == "" {
		return nil, nil
	}
	return codexhistory.MessagesWithLimit(threadID, limit)
}

func submittedUserContent(rawInput string) (string, bool) {
	content := strings.TrimRight(rawInput, "\r\n")
	if content == "" || isPureCtrlC(content) {
		return "", false
	}
	return content, true
}

func isPureCtrlC(value string) bool {
	if value == "" {
		return false
	}
	for _, char := range value {
		if char != '\x03' {
			return false
		}
	}
	return true
}

func absDuration(value time.Duration) time.Duration {
	if value < 0 {
		return -value
	}
	return value
}

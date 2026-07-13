package httpapi

import (
	"context"

	"github.com/gaixianggeng/mimi-remote/internal/codexhistory"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
	"github.com/gaixianggeng/mimi-remote/internal/session"
)

type SessionRuntime interface {
	// REST API 只依赖这个稳定边界；当前实现只面向 Codex app-server thread。
	ListSessions(ctx context.Context, projectID string, limit int, cursor sessionPageCursor, hasCursor bool) (SessionListPage, error)
	CreateSession(ctx context.Context, req RuntimeCreateRequest) (RuntimeCreateResult, error)
	SessionDetail(ctx context.Context, id string, afterSeq int64) (SessionDetail, error)
	StopSession(ctx context.Context, id string) error
	SessionMessages(ctx context.Context, id string, before string, limit int) (codexhistory.MessagePage, error)
	SessionTrace(ctx context.Context, id string) ([]session.TraceEvent, error)
}

type SessionListPage struct {
	Sessions   []session.SessionSnapshot
	NextCursor string
	HasMore    bool
}

type RuntimeCreateRequest struct {
	Project         projects.Project
	Prompt          string
	ResumeID        string
	Title           string
	Cols            int
	Rows            int
	ClientMessageID string
}

type RuntimeCreateResult struct {
	Snapshot    session.SessionSnapshot
	LiveSession *session.Session
}

type SessionDetail struct {
	Snapshot     session.SessionSnapshot
	RecentOutput string
	LastSeq      int64
}

func emptyMessagePage() codexhistory.MessagePage {
	return codexhistory.MessagePage{Messages: []codexhistory.Message{}}
}

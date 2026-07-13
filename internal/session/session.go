package session

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
	"github.com/gaixianggeng/mimi-remote/internal/ring"
)

type Options struct {
	CodexBin     string
	DefaultArgs  []string
	Env          map[string]string
	OutputBuffer int
}

type Manager struct {
	options  Options
	mu       sync.Mutex
	sessions map[string]*Session
}

type Session struct {
	ID        string `json:"id"`
	ProjectID string `json:"project_id"`
	Project   string `json:"project"`
	Dir       string `json:"dir"`
	Title     string `json:"title"`
	Status    string `json:"status"`
	Source    string `json:"source"`
	ResumeID  string `json:"resume_id,omitempty"`
	// HistoryThreadID 是运行态 session 与 Codex SQLite/rollout thread 的内存映射。
	// 新建会话没有 resume_id，Codex 进程启动后才会生成真实 thread id；Go 发现后写到这里，
	// 让结构化消息读取继续走后端，iOS 只消费 message_completed。
	HistoryThreadID string    `json:"history_thread_id,omitempty"`
	CreatedAt       time.Time `json:"created_at"`
	UpdatedAt       time.Time `json:"updated_at"`

	cmd    *exec.Cmd
	ptmx   *os.File
	cancel context.CancelFunc
	buffer *ring.Buffer

	mu                sync.Mutex
	writeMu           sync.Mutex
	termCols          int
	termRows          int
	subscribers       map[chan OutputChunk]struct{}
	outputSeq         int64
	outputReplay      []OutputChunk
	outputReplayBytes int
	submittedMessages []SubmittedMessage
	trace             []TraceEvent
	exit              ExitResult
	done              chan struct{}
}

// SessionSnapshot 是对外返回的会话数据视图，不包含 mutex、PTY、buffer 等运行态字段。
// 这样快照可以按值传递和 JSON 序列化，同时不会复制正在使用的锁。
type SessionSnapshot struct {
	ID              string    `json:"id"`
	ProjectID       string    `json:"project_id"`
	Project         string    `json:"project"`
	Dir             string    `json:"dir"`
	Title           string    `json:"title"`
	Status          string    `json:"status"`
	Source          string    `json:"source"`
	ResumeID        string    `json:"resume_id,omitempty"`
	HistoryThreadID string    `json:"history_thread_id,omitempty"`
	CreatedAt       time.Time `json:"created_at"`
	UpdatedAt       time.Time `json:"updated_at"`
	// 以下字段来自 app-server 结构化运行时；PTY fallback 会尽量填充水位字段。
	// 全部保持 omitempty，旧 iOS 客户端忽略即可，不破坏迁移前协议。
	Preview         string            `json:"preview,omitempty"`
	ActiveTurnID    string            `json:"active_turn_id,omitempty"`
	LastSeq         int64             `json:"last_seq,omitempty"`
	Revision        int64             `json:"revision,omitempty"`
	Usage           *UsageSummary     `json:"usage,omitempty"`
	PendingApproval *ApprovalSummary  `json:"pending_approval,omitempty"`
	RateLimit       *RateLimitSummary `json:"rate_limit,omitempty"`
	Context         *ContextSnapshot  `json:"context,omitempty"`
}

// ContextSnapshot 是 iOS 右侧状态栏使用的轻量上下文投影。
// 它只保留 app-server 已结构化暴露的状态摘要，完整日志、diff 和工具结果仍走各自面板，
// 避免侧边栏订阅高频大 payload。
type ContextSnapshot struct {
	SessionID   string              `json:"session_id,omitempty"`
	ThreadID    string              `json:"thread_id,omitempty"`
	Status      *ContextStatus      `json:"status,omitempty"`
	Environment *ContextEnvironment `json:"environment,omitempty"`
	Git         *ContextGitInfo     `json:"git,omitempty"`
	Tasks       []ContextTask       `json:"tasks,omitempty"`
	Sources     []ContextSource     `json:"sources,omitempty"`
	Subagents   []ContextSubagent   `json:"subagents,omitempty"`
	UpdatedAt   time.Time           `json:"updated_at,omitempty"`
}

type ContextStatus struct {
	Type        string   `json:"type,omitempty"`
	ActiveFlags []string `json:"active_flags,omitempty"`
}

type ContextEnvironment struct {
	ID       string `json:"id,omitempty"`
	Kind     string `json:"kind,omitempty"`
	Label    string `json:"label,omitempty"`
	CWD      string `json:"cwd,omitempty"`
	Provider string `json:"provider,omitempty"`
}

type ContextGitInfo struct {
	SHA       string `json:"sha,omitempty"`
	Branch    string `json:"branch,omitempty"`
	OriginURL string `json:"origin_url,omitempty"`
}

type ContextTask struct {
	ID       string `json:"id,omitempty"`
	Kind     string `json:"kind,omitempty"`
	Title    string `json:"title,omitempty"`
	Subtitle string `json:"subtitle,omitempty"`
	Status   string `json:"status,omitempty"`
}

type ContextSource struct {
	ID       string `json:"id,omitempty"`
	Kind     string `json:"kind,omitempty"`
	Label    string `json:"label,omitempty"`
	Subtitle string `json:"subtitle,omitempty"`
}

type ContextSubagent struct {
	ID             string `json:"id,omitempty"`
	ParentThreadID string `json:"parent_thread_id,omitempty"`
	Nickname       string `json:"nickname,omitempty"`
	Role           string `json:"role,omitempty"`
	Status         string `json:"status,omitempty"`
}

const promptSubmitDelay = 180 * time.Millisecond
const maxOutputReplayBytes = 256 * 1024
const maxOutputReplayChunks = 256
const maxSubmittedMessages = 128
const maxTraceEvents = 256

// OutputChunk 是实时 PTY 输出块；Seq 只用于客户端去重和回放水位，不改变原始终端内容。
type OutputChunk struct {
	Seq  int64
	Data []byte
}

type OutputSnapshot struct {
	Data    string
	LastSeq int64
}

// UsageSummary 是移动端展示用的轻量 token/cost 视图，不暴露 provider 内部细节。
type UsageSummary struct {
	InputTokens  int64    `json:"input_tokens,omitempty"`
	OutputTokens int64    `json:"output_tokens,omitempty"`
	TotalTokens  int64    `json:"total_tokens,omitempty"`
	CostUSD      *float64 `json:"cost_usd,omitempty"`
}

// ApprovalSummary 只放列表/详情需要的审批摘要；完整审批上下文走 WebSocket approval_request。
type ApprovalSummary struct {
	ID    string `json:"id"`
	Title string `json:"title"`
	Kind  string `json:"kind"`
	Count int    `json:"count,omitempty"`
}

// RateLimitSummary 是账号级限额信号的移动端摘要，供列表 chip/诊断展示。
type RateLimitSummary struct {
	LimitID              string   `json:"limit_id,omitempty"`
	LimitName            string   `json:"limit_name,omitempty"`
	PlanType             string   `json:"plan_type,omitempty"`
	ReachedType          string   `json:"reached_type,omitempty"`
	PrimaryUsedPercent   *float64 `json:"primary_used_percent,omitempty"`
	SecondaryUsedPercent *float64 `json:"secondary_used_percent,omitempty"`
	PrimaryResetsAt      *int64   `json:"primary_resets_at,omitempty"`
	SecondaryResetsAt    *int64   `json:"secondary_resets_at,omitempty"`
	HasCredits           *bool    `json:"has_credits,omitempty"`
	CreditsUnlimited     *bool    `json:"credits_unlimited,omitempty"`
	CreditBalance        string   `json:"credit_balance,omitempty"`
}

// SubmittedMessage 记录移动端提交过、带 client_message_id 的用户消息。
// 它只服务当前内存会话的 history/live 对齐：rollout 落盘后，后端可以把同一条用户消息
// 标回 client id，避免 iOS 在刷新历史时看到 client:* 和 rollout:* 两条重复用户气泡。
type SubmittedMessage struct {
	ClientMessageID string
	Content         string
	CreatedAt       time.Time
}

// TraceEvent 是会话内存里的轻量诊断事件，只记录水位和体积，不复制完整终端输出。
// 它借鉴 Codex rollout trace 的“热路径先记原始事实，排障时再还原”的思路，但保持 MVP：只保留最近窗口。
type TraceEvent struct {
	Time        time.Time `json:"time"`
	Type        string    `json:"type"`
	Seq         int64     `json:"seq,omitempty"`
	AfterSeq    int64     `json:"after_seq,omitempty"`
	Bytes       int       `json:"bytes,omitempty"`
	Chunks      int       `json:"chunks,omitempty"`
	Subscribers int       `json:"subscribers,omitempty"`
	Sent        int       `json:"sent,omitempty"`
	Dropped     int       `json:"dropped,omitempty"`
	Reason      string    `json:"reason,omitempty"`
}

type ExitResult struct {
	Code   int    `json:"code"`
	Reason string `json:"reason"`
}

type CreateRequest struct {
	Project         projects.Project
	Prompt          string
	ResumeID        string
	Title           string
	Cols            int
	Rows            int
	ClientMessageID string
}

func NewManager(options Options) *Manager {
	if options.CodexBin == "" {
		options.CodexBin = "codex"
	}
	if options.OutputBuffer <= 0 {
		options.OutputBuffer = 128 * 1024
	}
	return &Manager{options: options, sessions: map[string]*Session{}}
}

func (m *Manager) Create(req CreateRequest) (*Session, error) {
	if req.Cols < 20 || req.Cols > 300 {
		req.Cols = 120
	}
	if req.Rows < 5 || req.Rows > 100 {
		req.Rows = 32
	}

	id := ""
	if req.ResumeID != "" {
		id = "codex_" + req.ResumeID
		if existing, ok := m.Get(id); ok {
			if existing.Snapshot().Status == "running" {
				if prompt := strings.TrimSpace(req.Prompt); prompt != "" {
					// 旧的 iPad 状态可能还把这个线程当成 history；如果服务端已经有运行中的
					// resume session，继续复用它，但必须把本次输入写进 PTY，避免请求被静默吞掉。
					if err := existing.Write(prompt + "\r"); err != nil {
						return nil, err
					}
				}
				return existing, nil
			}
			m.remove(id)
		}
	} else {
		var err error
		id, err = newID()
		if err != nil {
			return nil, err
		}
	}

	ctx, cancel := context.WithCancel(context.Background())
	args := m.codexArgs(req)
	title := req.Title
	if title == "" {
		title = sessionTitle(req.Prompt)
	}

	cmd := exec.CommandContext(ctx, m.options.CodexBin, args...)
	cmd.Dir = req.Project.RealPath
	cmd.Env = buildEnv(m.options.Env)
	// creack/pty 会为子进程创建新的 session 和控制终端；不要额外设置 Setpgid，
	// macOS 下 Setsid + Setpgid 组合会导致 fork/exec 返回 operation not permitted。

	ptmx, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: uint16(req.Rows), Cols: uint16(req.Cols)})
	if err != nil {
		cancel()
		return nil, fmt.Errorf("启动 Codex 失败：%w", err)
	}

	now := time.Now()
	s := &Session{
		ID:          id,
		ProjectID:   req.Project.ID,
		Project:     req.Project.Name,
		Dir:         req.Project.Path,
		Title:       title,
		Status:      "running",
		Source:      sessionSource(req.ResumeID),
		ResumeID:    req.ResumeID,
		CreatedAt:   now,
		UpdatedAt:   now,
		cmd:         cmd,
		ptmx:        ptmx,
		cancel:      cancel,
		buffer:      ring.New(m.options.OutputBuffer),
		termCols:    req.Cols,
		termRows:    req.Rows,
		subscribers: make(map[chan OutputChunk]struct{}),
		done:        make(chan struct{}),
	}

	m.mu.Lock()
	m.sessions[id] = s
	m.mu.Unlock()
	s.RecordTrace(TraceEvent{Type: "session_created"})

	go s.readLoop()
	go s.waitLoop()
	return s, nil
}

func sessionSource(resumeID string) string {
	if strings.TrimSpace(resumeID) != "" {
		return "codex"
	}
	return "agentd"
}

func (m *Manager) remove(id string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.sessions, id)
}

func (m *Manager) codexArgs(req CreateRequest) []string {
	prompt := strings.TrimSpace(req.Prompt)
	if req.ResumeID != "" {
		args := append([]string{"resume"}, m.options.DefaultArgs...)
		args = append(args, req.ResumeID)
		if prompt != "" {
			args = append(args, prompt)
		}
		return args
	}
	args := append([]string{}, m.options.DefaultArgs...)
	if prompt != "" {
		args = append(args, prompt)
	}
	return args
}

func sessionTitle(prompt string) string {
	prompt = strings.TrimSpace(prompt)
	if prompt == "" {
		return "交互式 Codex 会话"
	}
	fields := strings.Fields(prompt)
	title := strings.Join(fields, " ")
	if len([]rune(title)) > 42 {
		runes := []rune(title)
		return string(runes[:42]) + "..."
	}
	return title
}

func buildEnv(extra map[string]string) []string {
	env := os.Environ()
	for k, v := range extra {
		env = append(env, k+"="+v)
	}
	return env
}

func newID() (string, error) {
	var b [12]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return "sess_" + hex.EncodeToString(b[:]), nil
}

func (m *Manager) Get(id string) (*Session, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, ok := m.sessions[id]
	return s, ok
}

func (m *Manager) List() []*Session {
	out := m.listSnapshot()
	sort.Slice(out, func(i, j int) bool {
		return out[i].CreatedAt.After(out[j].CreatedAt)
	})
	return out
}

func (m *Manager) ListUnsorted() []*Session {
	// HTTP sessions API 自己会按 updated_at/id 做最终排序；热路径用无序快照，
	// 避免 Manager 先按 created_at 排一次，分页前又重排一次。
	return m.listSnapshot()
}

func (m *Manager) listSnapshot() []*Session {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]*Session, 0, len(m.sessions))
	for _, s := range m.sessions {
		out = append(out, s)
	}
	return out
}

func (m *Manager) Stop(id string) error {
	s, ok := m.Get(id)
	if !ok {
		return fmt.Errorf("session 不存在：%s", id)
	}
	return s.Stop()
}

func (m *Manager) Shutdown() {
	for _, s := range m.List() {
		_ = s.Stop()
	}
}

func (s *Session) Snapshot() SessionSnapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.snapshotLocked()
}

func (s *Session) SnapshotIfProject(projectID string) (SessionSnapshot, bool) {
	return s.SnapshotIfProjectBeforeCursor(projectID, "", 0)
}

func (s *Session) SnapshotIfProjectBeforeCursor(projectID, cursorID string, cursorUpdatedAtMS int64) (SessionSnapshot, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	// 项目列表刷新是热路径：先在锁内做轻量 project 判断，避免无关 active session
	// 继续复制 buffer/subscriber/trace 等运行态字段再被 HTTP 层丢弃。
	if projectID != "" && s.ProjectID != projectID {
		return SessionSnapshot{}, false
	}
	if cursorID != "" && cursorUpdatedAtMS > 0 {
		updatedAtMS := s.updatedAtMSLocked()
		if updatedAtMS != cursorUpdatedAtMS {
			if updatedAtMS >= cursorUpdatedAtMS {
				return SessionSnapshot{}, false
			}
		} else if s.ID >= cursorID {
			return SessionSnapshot{}, false
		}
	}
	return s.snapshotLocked(), true
}

func (s *Session) snapshotLocked() SessionSnapshot {
	return SessionSnapshot{
		ID:              s.ID,
		ProjectID:       s.ProjectID,
		Project:         s.Project,
		Dir:             s.Dir,
		Title:           s.Title,
		Status:          s.Status,
		Source:          s.Source,
		ResumeID:        s.ResumeID,
		HistoryThreadID: s.HistoryThreadID,
		CreatedAt:       s.CreatedAt,
		UpdatedAt:       s.UpdatedAt,
		Preview:         trimPreviewLocked(s.Title),
		LastSeq:         s.outputSeq,
		Revision:        s.outputSeq,
	}
}

func trimPreviewLocked(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	runes := []rune(value)
	if len(runes) <= 96 {
		return value
	}
	return string(runes[:96]) + "..."
}

func (s *Session) updatedAtMSLocked() int64 {
	if !s.UpdatedAt.IsZero() {
		return s.UpdatedAt.UnixMilli()
	}
	if !s.CreatedAt.IsZero() {
		return s.CreatedAt.UnixMilli()
	}
	return 0
}

func (s *Session) RecentOutput() string {
	return s.RecentOutputSnapshot().Data
}

func (s *Session) RecentOutputSnapshot() OutputSnapshot {
	return s.OutputSince(0)
}

func (s *Session) OutputSince(afterSeq int64) OutputSnapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	if afterSeq > 0 {
		if afterSeq >= s.outputSeq {
			return OutputSnapshot{LastSeq: s.outputSeq}
		}
		if replay, ok := s.replayAfterLocked(afterSeq); ok {
			var builder strings.Builder
			for _, chunk := range replay {
				builder.Write(chunk.Data)
			}
			s.appendTraceLocked(TraceEvent{
				Type:     "output_since_replay",
				Seq:      s.outputSeq,
				AfterSeq: afterSeq,
				Chunks:   len(replay),
				Bytes:    builder.Len(),
			})
			return OutputSnapshot{Data: builder.String(), LastSeq: s.outputSeq}
		}
		s.appendTraceLocked(TraceEvent{Type: "output_since_snapshot", Seq: s.outputSeq, AfterSeq: afterSeq})
	}
	return s.recentOutputSnapshotLocked()
}

func (s *Session) TraceEvents() []TraceEvent {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]TraceEvent(nil), s.trace...)
}

func (s *Session) RecordTrace(event TraceEvent) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.appendTraceLocked(event)
}

func (s *Session) RecordSubmittedMessage(message SubmittedMessage) {
	if strings.TrimSpace(message.ClientMessageID) == "" || strings.TrimSpace(message.Content) == "" {
		return
	}
	if message.CreatedAt.IsZero() {
		message.CreatedAt = time.Now().UTC()
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.submittedMessages = append(s.submittedMessages, message)
	if len(s.submittedMessages) <= maxSubmittedMessages {
		return
	}
	copy(s.submittedMessages, s.submittedMessages[len(s.submittedMessages)-maxSubmittedMessages:])
	s.submittedMessages = s.submittedMessages[:maxSubmittedMessages]
}

func (s *Session) SubmittedMessages() []SubmittedMessage {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]SubmittedMessage(nil), s.submittedMessages...)
}

func (s *Session) SetHistoryThreadID(threadID string) bool {
	threadID = strings.TrimSpace(threadID)
	if threadID == "" {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.HistoryThreadID == threadID {
		return false
	}
	s.HistoryThreadID = threadID
	s.UpdatedAt = time.Now()
	return true
}

func (s *Session) Write(input string) error {
	if len(input) > 16*1024 {
		return fmt.Errorf("单次输入过大，最大 16KB")
	}
	s.mu.Lock()
	closed := s.Status != "running"
	ptmx := s.ptmx
	s.mu.Unlock()
	if closed || ptmx == nil {
		return fmt.Errorf("session 已结束")
	}

	s.writeMu.Lock()
	defer s.writeMu.Unlock()

	if body, ok := splitSubmittedPrompt(input); ok {
		// Codex TUI 会把快速连续字符识别成 paste burst，并在短窗口内把 Enter
		// 当作粘贴里的换行。把正文和提交键分开发，可以避免“文字进入输入框但没提交”。
		if _, err := ptmx.Write([]byte(body)); err != nil {
			return err
		}
		time.Sleep(promptSubmitDelay)
		_, err := ptmx.Write([]byte("\r"))
		return err
	}

	_, err := ptmx.Write([]byte(input))
	return err
}

func splitSubmittedPrompt(input string) (string, bool) {
	if len(input) <= 1 || !strings.HasSuffix(input, "\r") {
		return input, false
	}
	body := strings.TrimSuffix(input, "\r")
	if body == "" {
		return input, false
	}
	return body, true
}

func (s *Session) Resize(cols, rows int) error {
	if cols < 20 || cols > 300 || rows < 5 || rows > 100 {
		return fmt.Errorf("终端尺寸超出范围")
	}
	s.mu.Lock()
	if s.termCols == cols && s.termRows == rows {
		s.mu.Unlock()
		return nil
	}
	ptmx := s.ptmx
	s.mu.Unlock()
	if ptmx == nil {
		return fmt.Errorf("session 已结束")
	}
	if err := pty.Setsize(ptmx, &pty.Winsize{Rows: uint16(rows), Cols: uint16(cols)}); err != nil {
		return err
	}
	s.mu.Lock()
	s.termCols = cols
	s.termRows = rows
	s.mu.Unlock()
	return nil
}

func (s *Session) Stop() error {
	s.mu.Lock()
	if s.Status != "running" {
		s.mu.Unlock()
		return nil
	}
	s.Status = "stopping"
	s.UpdatedAt = time.Now()
	s.appendTraceLocked(TraceEvent{Type: "stop_requested", Seq: s.outputSeq})
	cmd := s.cmd
	cancel := s.cancel
	s.mu.Unlock()

	if cancel != nil {
		cancel()
	}
	if cmd != nil && cmd.Process != nil {
		// 先温和退出，2 秒后仍未退出再强杀进程组。
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		select {
		case <-s.done:
			return nil
		case <-time.After(2 * time.Second):
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		}
	}
	return nil
}

func (s *Session) Attach() (<-chan OutputChunk, func(), error) {
	ch, _, _, detach, err := s.AttachAfter(0)
	return ch, detach, err
}

func (s *Session) AttachAfter(afterSeq int64) (<-chan OutputChunk, []OutputChunk, *OutputSnapshot, func(), error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.Status != "running" {
		return nil, nil, nil, nil, fmt.Errorf("session 已结束")
	}
	if s.subscribers == nil {
		s.subscribers = make(map[chan OutputChunk]struct{})
	}
	ch := make(chan OutputChunk, 128)
	s.subscribers[ch] = struct{}{}
	detached := false
	detach := func() {
		s.mu.Lock()
		if !detached {
			delete(s.subscribers, ch)
			close(ch)
			detached = true
		}
		s.mu.Unlock()
	}
	if afterSeq > 0 {
		if replay, ok := s.replayAfterLocked(afterSeq); ok {
			s.appendTraceLocked(TraceEvent{
				Type:        "attach_replay",
				Seq:         s.outputSeq,
				AfterSeq:    afterSeq,
				Chunks:      len(replay),
				Subscribers: len(s.subscribers),
			})
			return ch, replay, nil, detach, nil
		}
	}
	snapshot := s.recentOutputSnapshotLocked()
	eventType := "attach_snapshot"
	if afterSeq > 0 {
		eventType = "attach_snapshot_fallback"
	}
	s.appendTraceLocked(TraceEvent{
		Type:        eventType,
		Seq:         s.outputSeq,
		AfterSeq:    afterSeq,
		Bytes:       len(snapshot.Data),
		Subscribers: len(s.subscribers),
	})
	return ch, nil, &snapshot, detach, nil
}

func (s *Session) broadcastOutput(chunk []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.buffer != nil {
		// 输出内容和水位必须在同一把锁下推进；否则 recent_output 可能拿到旧内容、
		// 新 last_seq，客户端就会误丢后续实时块。
		s.buffer.Write(chunk)
	}
	s.outputSeq++
	output := OutputChunk{Seq: s.outputSeq, Data: append([]byte(nil), chunk...)}
	s.appendReplayLocked(output)
	sent := 0
	dropped := 0
	for ch := range s.subscribers {
		select {
		case ch <- output:
			sent++
		default:
			dropped++
			// 前端太慢时丢弃实时块；最近输出仍在 ring buffer 中，刷新可追回。
			// seq 让客户端能识别重连/回放里的重复实时块，避免日志面板重复渲染。
		}
	}
	s.appendTraceLocked(TraceEvent{
		Type:        "output_chunk",
		Seq:         output.Seq,
		Bytes:       len(output.Data),
		Subscribers: len(s.subscribers),
		Sent:        sent,
		Dropped:     dropped,
	})
}

func (s *Session) recentOutputSnapshotLocked() OutputSnapshot {
	data := ""
	if s.buffer != nil {
		data = s.buffer.String()
	}
	return OutputSnapshot{Data: data, LastSeq: s.outputSeq}
}

func (s *Session) replayAfterLocked(afterSeq int64) ([]OutputChunk, bool) {
	if afterSeq >= s.outputSeq {
		return []OutputChunk{}, true
	}
	if len(s.outputReplay) == 0 {
		return nil, false
	}
	idx := -1
	for i, chunk := range s.outputReplay {
		if chunk.Seq > afterSeq {
			idx = i
			break
		}
	}
	if idx < 0 {
		return []OutputChunk{}, true
	}
	if s.outputReplay[idx].Seq != afterSeq+1 {
		return nil, false
	}
	replay := make([]OutputChunk, 0, len(s.outputReplay)-idx)
	for _, chunk := range s.outputReplay[idx:] {
		replay = append(replay, OutputChunk{Seq: chunk.Seq, Data: append([]byte(nil), chunk.Data...)})
	}
	return replay, true
}

func (s *Session) appendReplayLocked(chunk OutputChunk) {
	if len(chunk.Data) == 0 {
		return
	}
	if len(chunk.Data) > maxOutputReplayBytes {
		// 单块输出已经超过短线 replay 窗口，存进去也会立刻被裁掉。
		// 直接清空旧窗口，明确制造 replay 缺口：断线客户端会走 recent_output 快照兜底。
		s.outputReplay = nil
		s.outputReplayBytes = 0
		return
	}
	s.outputReplay = append(s.outputReplay, OutputChunk{Seq: chunk.Seq, Data: append([]byte(nil), chunk.Data...)})
	s.outputReplayBytes += len(chunk.Data)
	s.trimReplayLocked()
}

func (s *Session) trimReplayLocked() {
	if len(s.outputReplay) <= maxOutputReplayChunks && s.outputReplayBytes <= maxOutputReplayBytes {
		return
	}

	keepStart := len(s.outputReplay)
	keptBytes := 0
	// replay 是给短线重连补洞用的，不承担长期日志存储；从尾部一次算出可保留窗口，
	// 避免高频输出超限时反复从头 slice，也释放旧 chunk 持有的底层字节数组。
	for keepStart > 0 && len(s.outputReplay)-keepStart < maxOutputReplayChunks {
		candidate := s.outputReplay[keepStart-1]
		candidateBytes := len(candidate.Data)
		if keptBytes+candidateBytes > maxOutputReplayBytes {
			break
		}
		keepStart--
		keptBytes += candidateBytes
	}
	for index := 0; index < keepStart; index++ {
		s.outputReplay[index] = OutputChunk{}
	}
	kept := s.outputReplay[keepStart:]
	next := make([]OutputChunk, len(kept))
	copy(next, kept)
	s.outputReplay = next
	s.outputReplayBytes = keptBytes
}

func (s *Session) appendTraceLocked(event TraceEvent) {
	if event.Type == "" {
		return
	}
	if event.Time.IsZero() {
		event.Time = time.Now()
	}
	s.trace = append(s.trace, event)
	if len(s.trace) <= maxTraceEvents {
		return
	}
	copy(s.trace, s.trace[len(s.trace)-maxTraceEvents:])
	s.trace = s.trace[:maxTraceEvents]
}

func (s *Session) Done() <-chan struct{} {
	return s.done
}

func (s *Session) ExitResult() ExitResult {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.exit
}

func (s *Session) readLoop() {
	buf := make([]byte, 4096)
	for {
		n, err := s.ptmx.Read(buf)
		if n > 0 {
			chunk := append([]byte(nil), buf[:n]...)
			s.broadcastOutput(chunk)
		}
		if err != nil {
			if err != io.EOF {
				s.broadcastOutput([]byte("\r\n[agentd] PTY 读取结束：" + err.Error() + "\r\n"))
			}
			return
		}
	}
}

func (s *Session) waitLoop() {
	err := s.cmd.Wait()
	exit := ExitResult{Code: 0, Reason: "process exited"}
	if err != nil {
		exit.Code = exitCode(err)
		exit.Reason = err.Error()
	}
	_ = s.ptmx.Close()

	s.mu.Lock()
	s.Status = "closed"
	s.UpdatedAt = time.Now()
	s.exit = exit
	s.appendTraceLocked(TraceEvent{Type: "session_exit", Seq: s.outputSeq, Reason: exit.Reason})
	s.mu.Unlock()
	close(s.done)
}

func exitCode(err error) int {
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		if status, ok := exitErr.Sys().(syscall.WaitStatus); ok {
			return status.ExitStatus()
		}
	}
	return -1
}

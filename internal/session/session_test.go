package session

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/projects"
	"github.com/gaixianggeng/mimi-remote/internal/ring"
)

func TestManagerCodexArgsForPromptAndResume(t *testing.T) {
	manager := NewManager(Options{DefaultArgs: []string{"--no-alt-screen", "--sandbox", "workspace-write"}})

	got := manager.codexArgs(CreateRequest{Prompt: "  帮我检查测试  "})
	want := []string{"--no-alt-screen", "--sandbox", "workspace-write", "帮我检查测试"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("新会话参数不匹配\nwant=%v\ngot=%v", want, got)
	}

	got = manager.codexArgs(CreateRequest{ResumeID: "thread_123", Prompt: "继续"})
	want = []string{"resume", "--no-alt-screen", "--sandbox", "workspace-write", "thread_123", "继续"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("恢复会话参数不匹配\nwant=%v\ngot=%v", want, got)
	}
}

func TestSessionTitleAndSourceDefaults(t *testing.T) {
	if got := sessionTitle(""); got != "交互式 Codex 会话" {
		t.Fatalf("空 prompt 标题异常：%q", got)
	}
	if got := sessionTitle("  第一行\n第二行  "); got != "第一行 第二行" {
		t.Fatalf("标题应压平空白字符：%q", got)
	}
	longTitle := sessionTitle(strings.Repeat("界", 50))
	if !strings.HasSuffix(longTitle, "...") || len([]rune(longTitle)) != 45 {
		t.Fatalf("长标题应按 rune 截断并追加省略号：%q", longTitle)
	}
	if got := sessionSource(""); got != "agentd" {
		t.Fatalf("新会话 source 异常：%q", got)
	}
	if got := sessionSource("thread_1"); got != "codex" {
		t.Fatalf("恢复会话 source 异常：%q", got)
	}
}

func TestSessionSnapshotIfProjectFiltersBeforeCopy(t *testing.T) {
	session := &Session{
		ID:          "sess_demo",
		ProjectID:   "demo",
		Status:      "running",
		buffer:      ring.New(1024),
		subscribers: map[chan OutputChunk]struct{}{},
		trace:       []TraceEvent{{Type: "created"}},
		done:        make(chan struct{}),
	}

	if _, ok := session.SnapshotIfProject("other"); ok {
		t.Fatal("非目标项目不应返回 active session 快照")
	}

	snapshot, ok := session.SnapshotIfProject("demo")
	if !ok {
		t.Fatal("目标项目应返回 active session 快照")
	}
	if snapshot.ID != "sess_demo" || snapshot.ProjectID != "demo" {
		t.Fatalf("快照基础字段异常：id=%q project_id=%q", snapshot.ID, snapshot.ProjectID)
	}
	data, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{"buffer", "subscribers", "trace", "done"} {
		if strings.Contains(string(data), field) {
			t.Fatalf("快照 JSON 不应暴露运行态字段 %q：%s", field, data)
		}
	}
}

func TestSessionSnapshotIfProjectBeforeCursorFiltersInLock(t *testing.T) {
	updatedAt := time.UnixMilli(1_780_308_003_000)
	session := &Session{
		ID:        "sess_beta",
		ProjectID: "demo",
		Status:    "running",
		UpdatedAt: updatedAt,
		buffer:    ring.New(1024),
	}

	if _, ok := session.SnapshotIfProjectBeforeCursor("demo", "sess_alpha", updatedAt.UnixMilli()); ok {
		t.Fatal("同一 updated_at 下 id 大于等于 cursor 的运行会话不应返回")
	}

	snapshot, ok := session.SnapshotIfProjectBeforeCursor("demo", "sess_gamma", updatedAt.UnixMilli())
	if !ok {
		t.Fatal("同一 updated_at 下 id 小于 cursor 的运行会话应返回")
	}
	if snapshot.ID != "sess_beta" {
		t.Fatalf("cursor 过滤后的快照 ID 异常：%q", snapshot.ID)
	}
}

func TestManagerListUnsortedKeepsListOrderingCompatible(t *testing.T) {
	manager := NewManager(Options{})
	older := &Session{ID: "sess_old", CreatedAt: time.Unix(10, 0)}
	newer := &Session{ID: "sess_new", CreatedAt: time.Unix(20, 0)}
	manager.sessions[older.ID] = older
	manager.sessions[newer.ID] = newer

	sorted := manager.List()
	if len(sorted) != 2 || sorted[0].ID != newer.ID || sorted[1].ID != older.ID {
		t.Fatalf("List 应继续按 CreatedAt 降序兼容旧行为，got=%v", sessionIDs(sorted))
	}

	unsorted := manager.ListUnsorted()
	if len(unsorted) != 2 {
		t.Fatalf("ListUnsorted 应返回完整快照，got=%v", sessionIDs(unsorted))
	}
}

func TestCreateWithFakeCodexUsesProjectDirAndBoundsTerminalSize(t *testing.T) {
	projectDir := t.TempDir()
	realProjectDir, err := filepath.EvalSymlinks(projectDir)
	if err != nil {
		t.Fatal(err)
	}
	fakeCodex := filepath.Join(t.TempDir(), "codex")
	writeFakeCodex(t, fakeCodex)

	manager := NewManager(Options{
		CodexBin:     fakeCodex,
		DefaultArgs:  []string{"--no-alt-screen"},
		Env:          map[string]string{"TERM": "xterm-agentd-test"},
		OutputBuffer: 1024,
	})
	session, err := manager.Create(CreateRequest{
		Project: projects.Project{
			ID:       "demo",
			Name:     "Demo",
			Path:     projectDir,
			RealPath: projectDir,
		},
		Prompt: "hello world",
		Cols:   1,
		Rows:   999,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Shutdown()

	select {
	case <-session.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("fake codex 未按预期退出")
	}

	snapshot := session.Snapshot()
	if snapshot.ProjectID != "demo" || snapshot.Dir != projectDir {
		t.Fatalf("session 未保存 allowlist 项目信息：project_id=%q dir=%q", snapshot.ProjectID, snapshot.Dir)
	}
	if snapshot.Title != "hello world" {
		t.Fatalf("标题应来自 prompt：%q", snapshot.Title)
	}
	if snapshot.Source != "agentd" {
		t.Fatalf("新会话 source 应为 agentd：%q", snapshot.Source)
	}
	if session.termCols != 120 || session.termRows != 32 {
		t.Fatalf("非法终端尺寸应回落到默认值，cols=%d rows=%d", session.termCols, session.termRows)
	}

	output := session.RecentOutput()
	if !strings.Contains(output, "cwd="+realProjectDir) {
		t.Fatalf("fake codex 应在项目目录运行，输出：%q", output)
	}
	if !strings.Contains(output, "args=--no-alt-screen hello world") {
		t.Fatalf("fake codex 参数异常，输出：%q", output)
	}
	if !strings.Contains(output, "TERM=xterm-agentd-test") {
		t.Fatalf("session 环境变量未传入子进程，输出：%q", output)
	}
}

func TestCreateExistingResumeSessionWritesPrompt(t *testing.T) {
	projectDir := t.TempDir()
	fakeCodex := filepath.Join(t.TempDir(), "codex")
	inputLog := filepath.Join(t.TempDir(), "input.log")
	writeInteractiveFakeCodex(t, fakeCodex, inputLog)

	manager := NewManager(Options{
		CodexBin:     fakeCodex,
		DefaultArgs:  []string{"--no-alt-screen"},
		Env:          map[string]string{"TERM": "xterm-agentd-test"},
		OutputBuffer: 1024,
	})
	defer manager.Shutdown()

	project := projects.Project{
		ID:       "demo",
		Name:     "Demo",
		Path:     projectDir,
		RealPath: projectDir,
	}
	first, err := manager.Create(CreateRequest{
		Project:  project,
		ResumeID: "thread_123",
		Prompt:   "第一次",
		Cols:     120,
		Rows:     32,
	})
	if err != nil {
		t.Fatal(err)
	}

	second, err := manager.Create(CreateRequest{
		Project:  project,
		ResumeID: "thread_123",
		Prompt:   "第二次",
		Cols:     120,
		Rows:     32,
	})
	if err != nil {
		t.Fatal(err)
	}
	if first != second {
		t.Fatal("同一个 resumeID 的运行中会话应复用已有 session")
	}

	deadline := time.Now().Add(2 * time.Second)
	for {
		data, _ := os.ReadFile(inputLog)
		if strings.Contains(string(data), "第二次") {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("复用运行中 resume session 时没有把 prompt 写入 PTY，input.log=%q", string(data))
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestSplitSubmittedPrompt(t *testing.T) {
	tests := []struct {
		name string
		in   string
		body string
		ok   bool
	}{
		{name: "submitted prompt", in: "hello\r", body: "hello", ok: true},
		{name: "raw enter", in: "\r", body: "\r", ok: false},
		{name: "plain text", in: "hello", body: "hello", ok: false},
		{name: "double enter keeps first in body", in: "hello\r\r", body: "hello\r", ok: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			body, ok := splitSubmittedPrompt(tt.in)
			if body != tt.body || ok != tt.ok {
				t.Fatalf("splitSubmittedPrompt(%q) = (%q, %v)，期望 (%q, %v)", tt.in, body, ok, tt.body, tt.ok)
			}
		})
	}
}

func TestSessionWriteSubmittedPromptSeparatesEnter(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	defer writer.Close()

	session := &Session{
		Status: "running",
		ptmx:   writer,
	}

	done := make(chan error, 1)
	go func() {
		done <- session.Write("hello\r")
	}()

	first := make(chan string, 1)
	go func() {
		buf := make([]byte, len("hello"))
		_, err := io.ReadFull(reader, buf)
		if err != nil {
			first <- "read error: " + err.Error()
			return
		}
		first <- string(buf)
	}()

	select {
	case got := <-first:
		if got != "hello" {
			t.Fatalf("应先写入 prompt 正文，实际 %q", got)
		}
	case <-time.After(time.Second):
		t.Fatal("没有读到 prompt 正文")
	}

	enter := make(chan string, 1)
	go func() {
		buf := make([]byte, 1)
		_, err := io.ReadFull(reader, buf)
		if err != nil {
			enter <- "read error: " + err.Error()
			return
		}
		enter <- string(buf)
	}()

	select {
	case got := <-enter:
		if got != "\r" {
			t.Fatalf("应补发 Enter，实际 %q", got)
		}
	case <-time.After(time.Second):
		t.Fatal("没有读到补发的 Enter")
	}

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Write 返回错误：%v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Write 没有结束")
	}
}

func TestAttachAllowsMultipleClientsReceiveBroadcast(t *testing.T) {
	session := &Session{
		Status:      "running",
		subscribers: make(map[chan OutputChunk]struct{}),
		done:        make(chan struct{}),
	}

	first, detachFirst, err := session.Attach()
	if err != nil {
		t.Fatalf("首次 attach 应成功：%v", err)
	}
	defer detachFirst()
	second, detachSecond, err := session.Attach()
	if err != nil {
		t.Fatalf("第二个客户端也应允许 attach：%v", err)
	}
	defer detachSecond()

	session.broadcastOutput([]byte("hello"))
	for name, ch := range map[string]<-chan OutputChunk{"first": first, "second": second} {
		select {
		case got := <-ch:
			if string(got.Data) != "hello" {
				t.Fatalf("%s 收到的输出异常：%q", name, string(got.Data))
			}
			if got.Seq != 1 {
				t.Fatalf("%s 收到的输出 seq 异常：%d", name, got.Seq)
			}
		case <-time.After(time.Second):
			t.Fatalf("%s 没有收到广播输出", name)
		}
	}
}

func TestRecentOutputSnapshotIncludesLastSeq(t *testing.T) {
	session := &Session{
		Status:      "running",
		buffer:      ring.New(1024),
		subscribers: make(map[chan OutputChunk]struct{}),
		done:        make(chan struct{}),
	}

	session.broadcastOutput([]byte("one"))
	session.broadcastOutput([]byte("-two"))

	snapshot := session.RecentOutputSnapshot()
	if snapshot.Data != "one-two" {
		t.Fatalf("最近输出内容异常：%q", snapshot.Data)
	}
	if snapshot.LastSeq != 2 {
		t.Fatalf("最近输出水位异常：%d", snapshot.LastSeq)
	}
}

func TestOutputSinceUsesReplayWindow(t *testing.T) {
	session := &Session{
		Status:      "running",
		buffer:      ring.New(1024),
		subscribers: make(map[chan OutputChunk]struct{}),
		done:        make(chan struct{}),
	}
	session.broadcastOutput([]byte("one"))
	session.broadcastOutput([]byte("-two"))
	session.broadcastOutput([]byte("-three"))

	delta := session.OutputSince(1)
	if delta.Data != "-two-three" {
		t.Fatalf("after_seq 可 replay 时应只返回增量，实际 %q", delta.Data)
	}
	if delta.LastSeq != 3 {
		t.Fatalf("增量水位异常：%d", delta.LastSeq)
	}

	empty := session.OutputSince(3)
	if empty.Data != "" || empty.LastSeq != 3 {
		t.Fatalf("客户端已到最新水位时不应返回旧输出：%+v", empty)
	}
}

func TestAttachAfterReplaysChunksAfterSequence(t *testing.T) {
	session := &Session{
		Status:      "running",
		buffer:      ring.New(1024),
		subscribers: make(map[chan OutputChunk]struct{}),
		done:        make(chan struct{}),
	}
	session.broadcastOutput([]byte("one"))
	session.broadcastOutput([]byte("two"))
	session.broadcastOutput([]byte("three"))

	_, replay, snapshot, detach, err := session.AttachAfter(1)
	if err != nil {
		t.Fatalf("AttachAfter 失败：%v", err)
	}
	defer detach()
	if snapshot != nil {
		t.Fatalf("可完整 replay 时不应退回快照：%+v", snapshot)
	}
	if len(replay) != 2 || replay[0].Seq != 2 || replay[1].Seq != 3 {
		t.Fatalf("replay 序列异常：%+v", replay)
	}
	if string(replay[0].Data)+string(replay[1].Data) != "twothree" {
		t.Fatalf("replay 内容异常：%q/%q", string(replay[0].Data), string(replay[1].Data))
	}
}

func TestAttachAfterFallsBackToSnapshotWhenReplayWindowHasGap(t *testing.T) {
	session := &Session{
		Status:      "running",
		buffer:      ring.New(8192),
		subscribers: make(map[chan OutputChunk]struct{}),
		done:        make(chan struct{}),
	}
	for i := 0; i < maxOutputReplayChunks+2; i++ {
		session.broadcastOutput([]byte("x"))
	}

	_, replay, snapshot, detach, err := session.AttachAfter(1)
	if err != nil {
		t.Fatalf("AttachAfter 失败：%v", err)
	}
	defer detach()
	if len(replay) != 0 {
		t.Fatalf("replay 缺口时应退回快照，实际 replay=%+v", replay)
	}
	if snapshot == nil || snapshot.LastSeq != int64(maxOutputReplayChunks+2) {
		t.Fatalf("快照水位异常：%+v", snapshot)
	}
	if len(snapshot.Data) != maxOutputReplayChunks+2 {
		t.Fatalf("快照内容长度异常：%d", len(snapshot.Data))
	}
}

func TestReplayWindowTrimsByBytesAndKeepsNewestChunks(t *testing.T) {
	session := &Session{
		Status:      "running",
		buffer:      ring.New(maxOutputReplayBytes * 2),
		subscribers: make(map[chan OutputChunk]struct{}),
		done:        make(chan struct{}),
	}
	chunkSize := maxOutputReplayBytes / 4
	for _, marker := range []string{"a", "b", "c", "d", "e"} {
		session.broadcastOutput([]byte(strings.Repeat(marker, chunkSize)))
	}

	if len(session.outputReplay) != 4 {
		t.Fatalf("replay 应按字节上限保留最新 4 块，got=%d", len(session.outputReplay))
	}
	if session.outputReplayBytes != maxOutputReplayBytes {
		t.Fatalf("replay 字节水位异常：got=%d want=%d", session.outputReplayBytes, maxOutputReplayBytes)
	}
	if session.outputReplay[0].Seq != 2 || session.outputReplay[3].Seq != 5 {
		t.Fatalf("replay 应保留 seq 2..5，got=%+v", session.outputReplay)
	}

	_, replay, snapshot, detach, err := session.AttachAfter(1)
	if err != nil {
		t.Fatalf("AttachAfter 失败：%v", err)
	}
	defer detach()
	if snapshot != nil {
		t.Fatalf("字节裁剪后仍连续的窗口不应退回快照：%+v", snapshot)
	}
	if len(replay) != 4 || replay[0].Seq != 2 || string(replay[0].Data[:1]) != "b" {
		t.Fatalf("replay 应从最新尾部窗口继续：%+v", replay)
	}
}

func TestReplayWindowSkipsOversizedChunkAndKeepsLaterContinuity(t *testing.T) {
	session := &Session{
		Status:      "running",
		buffer:      ring.New(maxOutputReplayBytes * 2),
		subscribers: make(map[chan OutputChunk]struct{}),
		done:        make(chan struct{}),
	}
	session.broadcastOutput([]byte("before"))
	session.broadcastOutput([]byte(strings.Repeat("x", maxOutputReplayBytes+1)))

	if len(session.outputReplay) != 0 || session.outputReplayBytes != 0 {
		t.Fatalf("超大块应直接清空 replay 窗口，replay=%+v bytes=%d", session.outputReplay, session.outputReplayBytes)
	}

	_, replay, snapshot, detach, err := session.AttachAfter(1)
	if err != nil {
		t.Fatalf("AttachAfter 失败：%v", err)
	}
	defer detach()
	if len(replay) != 0 || snapshot == nil || snapshot.LastSeq != 2 {
		t.Fatalf("超大块造成缺口时应退回快照：replay=%+v snapshot=%+v", replay, snapshot)
	}

	session.broadcastOutput([]byte("after"))
	_, replay, snapshot, detach, err = session.AttachAfter(2)
	if err != nil {
		t.Fatalf("AttachAfter 失败：%v", err)
	}
	defer detach()
	if snapshot != nil || len(replay) != 1 || replay[0].Seq != 3 || string(replay[0].Data) != "after" {
		t.Fatalf("超大块之后的新连续输出应可 replay：replay=%+v snapshot=%+v", replay, snapshot)
	}
}

func TestTraceEventsRecordReplayDecisionsAndAreBounded(t *testing.T) {
	session := &Session{
		Status:      "running",
		buffer:      ring.New(8192),
		subscribers: make(map[chan OutputChunk]struct{}),
		done:        make(chan struct{}),
	}
	session.broadcastOutput([]byte("one"))
	session.broadcastOutput([]byte("two"))

	_, replay, snapshot, detach, err := session.AttachAfter(1)
	if err != nil {
		t.Fatalf("AttachAfter 失败：%v", err)
	}
	defer detach()
	if snapshot != nil || len(replay) != 1 || replay[0].Seq != 2 {
		t.Fatalf("应按 seq 补 replay：replay=%+v snapshot=%+v", replay, snapshot)
	}

	events := session.TraceEvents()
	if !traceHas(events, "output_chunk") || !traceHas(events, "attach_replay") {
		t.Fatalf("trace 应记录输出和 replay 决策：%+v", events)
	}
	events[0].Type = "mutated"
	if session.TraceEvents()[0].Type == "mutated" {
		t.Fatal("TraceEvents 必须返回副本，不能让调用方污染内部窗口")
	}

	for i := 0; i < maxTraceEvents+5; i++ {
		session.RecordTrace(TraceEvent{Type: "manual"})
	}
	events = session.TraceEvents()
	if len(events) != maxTraceEvents {
		t.Fatalf("trace 窗口应保持固定上限，实际 %d", len(events))
	}
}

func sessionIDs(items []*Session) []string {
	ids := make([]string, 0, len(items))
	for _, item := range items {
		ids = append(ids, item.ID)
	}
	return ids
}

func traceHas(events []TraceEvent, eventType string) bool {
	for _, event := range events {
		if event.Type == eventType {
			return true
		}
	}
	return false
}

func writeFakeCodex(t *testing.T, path string) {
	t.Helper()
	// 脚本模拟 Codex CLI：打印 cwd、参数和关键环境变量，随后立即退出，让测试快速稳定。
	script := `#!/bin/sh
printf 'cwd=%s\n' "$PWD"
printf 'args=%s\n' "$*"
printf 'TERM=%s\n' "$TERM"
`
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
}

func writeInteractiveFakeCodex(t *testing.T, path, inputLog string) {
	t.Helper()
	// 脚本模拟长驻 Codex CLI：先打印启动参数，再把之后从 PTY 收到的输入落盘。
	script := fmt.Sprintf(`#!/bin/sh
printf 'args=%%s\n' "$*"
while IFS= read -r line; do
  printf '%%s\n' "$line" >> %s
done
`, shellQuote(inputLog))
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

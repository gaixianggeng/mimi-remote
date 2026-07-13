package httpapi

import (
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/codexhistory"
	sessionpkg "github.com/gaixianggeng/mimi-remote/internal/session"
)

func TestSubmittedUserContentStripsSubmitNewlinesAndIgnoresControls(t *testing.T) {
	cases := []struct {
		name   string
		input  string
		want   string
		wantOK bool
	}{
		{name: "strip_cr", input: "hello\r", want: "hello", wantOK: true},
		{name: "strip_crlf", input: "hello\r\n", want: "hello", wantOK: true},
		{name: "keep_internal_newline", input: "hello\nworld\r", want: "hello\nworld", wantOK: true},
		{name: "pure_enter", input: "\r", wantOK: false},
		{name: "pure_ctrl_c", input: "\x03", wantOK: false},
		{name: "ctrl_c_with_submit", input: "\x03\r", wantOK: false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := submittedUserContent(tc.input)
			if ok != tc.wantOK || got != tc.want {
				t.Fatalf("submittedUserContent(%q)=(%q,%v)，want (%q,%v)", tc.input, got, ok, tc.want, tc.wantOK)
			}
		})
	}
}

func TestAnnotateHistoryMessagesWithSubmittedClientIDs(t *testing.T) {
	now := time.Now().UTC()
	messages := []codexhistory.Message{
		{ID: "rollout:10", Role: "user", Content: "继续", CreatedAt: now.Add(2 * time.Second)},
		{ID: "rollout:20", Role: "assistant", Content: "好的", CreatedAt: now.Add(3 * time.Second)},
	}
	submitted := []sessionpkg.SubmittedMessage{{
		ClientMessageID: "client-continue",
		Content:         "继续",
		CreatedAt:       now,
	}}

	got := annotateHistoryMessagesWithSubmittedClientIDs(messages, submitted)

	if got[0].ID != "client:client-continue" ||
		got[0].ClientMessageID != "client-continue" ||
		got[0].Revision != 1 ||
		got[0].SendStatus != "confirmed" {
		t.Fatalf("历史用户消息未按 client id 标注：%+v", got[0])
	}
	if got[1].ID != "rollout:20" || got[1].ClientMessageID != "" {
		t.Fatalf("assistant 历史消息不应被标注 client id：%+v", got[1])
	}
	if messages[0].ID != "rollout:10" {
		t.Fatalf("annotate 不应修改输入切片：%+v", messages[0])
	}
}

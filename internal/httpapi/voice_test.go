package httpapi

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestVoiceTranscribeHandlerRequiresCodexLogin(t *testing.T) {
	router := &Router{cfg: config.Config{
		Voice: config.VoiceConfig{CodexAuthFile: filepath.Join(t.TempDir(), "missing-auth.json")},
	}}
	body := voiceTranscriptionRequest{
		Filename:    "clip.m4a",
		ContentType: "audio/mp4",
		AudioBase64: base64.StdEncoding.EncodeToString([]byte("fake audio")),
	}
	payload, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodPost, "/api/voice/transcribe", bytes.NewReader(payload))
	rec := httptest.NewRecorder()
	router.voiceTranscribeHandler(rec, req)

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d, body=%s", rec.Code, http.StatusServiceUnavailable, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "Codex 登录态") {
		t.Fatalf("response should explain missing Codex login, got %s", rec.Body.String())
	}
}

func TestVoiceTranscribeHandlerPostsMultipartToCodexSession(t *testing.T) {
	authFile := writeCodexAuthFile(t, "codex-access-token", "account-123")
	var sawRequest bool
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		sawRequest = true
		if req.Method != http.MethodPost {
			t.Fatalf("method = %s, want POST", req.Method)
		}
		if req.URL.Path != "/transcribe" {
			t.Fatalf("path = %s, want /transcribe", req.URL.Path)
		}
		if got := req.Header.Get("Authorization"); got != "Bearer codex-access-token" {
			t.Fatalf("authorization = %q", got)
		}
		if got := req.Header.Get("ChatGPT-Account-Id"); got != "account-123" {
			t.Fatalf("account id = %q", got)
		}
		if got := req.Header.Get("originator"); got != "Codex Desktop" {
			t.Fatalf("originator = %q", got)
		}
		if got := req.Header.Get("OAI-Product-Sku"); got != "CODEX" {
			t.Fatalf("product sku = %q", got)
		}
		if got := req.Header.Get("User-Agent"); !strings.Contains(got, "Codex Desktop/agentd") {
			t.Fatalf("user agent = %q", got)
		}
		if err := req.ParseMultipartForm(16 << 20); err != nil {
			t.Fatal(err)
		}
		if got := req.FormValue("language"); got != "zh" {
			t.Fatalf("language = %q", got)
		}
		file, header, err := req.FormFile("file")
		if err != nil {
			t.Fatal(err)
		}
		defer file.Close()
		if header.Filename != "clip.m4a" {
			t.Fatalf("filename = %q", header.Filename)
		}
		data, err := io.ReadAll(file)
		if err != nil {
			t.Fatal(err)
		}
		if string(data) != "fake audio" {
			t.Fatalf("uploaded audio = %q", string(data))
		}
		writeJSON(w, http.StatusOK, map[string]string{"text": "Codex 转写文字"})
	}))
	defer upstream.Close()

	router := &Router{cfg: config.Config{
		Voice: config.VoiceConfig{
			CodexTranscriptionBaseURL: upstream.URL,
			CodexAuthFile:             authFile,
		},
	}}
	body := voiceTranscriptionRequest{
		Filename:    "clip.m4a",
		ContentType: "audio/mp4",
		AudioBase64: base64.StdEncoding.EncodeToString([]byte("fake audio")),
		Language:    "zh_CN",
	}
	payload, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodPost, "/api/voice/transcribe", bytes.NewReader(payload))
	rec := httptest.NewRecorder()
	router.voiceTranscribeHandler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d, body=%s", rec.Code, http.StatusOK, rec.Body.String())
	}
	if !sawRequest {
		t.Fatal("upstream did not receive request")
	}
	var response voiceTranscriptionResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response.Text != "Codex 转写文字" {
		t.Fatalf("text = %q", response.Text)
	}
	if response.Model != codexVoiceTranscriptionModel {
		t.Fatalf("model = %q", response.Model)
	}
}

func TestVoiceTranscribeHandlerMapsEmptyCodexTranscriptToNoSpeech(t *testing.T) {
	authFile := writeCodexAuthFile(t, "codex-access-token", "account-123")
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{
			"text":          "",
			"asset_pointer": "sediment://file_empty",
		})
	}))
	defer upstream.Close()

	router := &Router{cfg: config.Config{
		Voice: config.VoiceConfig{
			CodexTranscriptionBaseURL: upstream.URL,
			CodexAuthFile:             authFile,
		},
	}}
	body := voiceTranscriptionRequest{
		Filename:    "clip.m4a",
		ContentType: "audio/mp4",
		AudioBase64: base64.StdEncoding.EncodeToString([]byte("fake audio")),
		Language:    "zh_CN",
	}
	payload, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodPost, "/api/voice/transcribe", bytes.NewReader(payload))
	rec := httptest.NewRecorder()
	router.voiceTranscribeHandler(rec, req)

	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want %d, body=%s", rec.Code, http.StatusUnprocessableEntity, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "没有识别到语音内容") {
		t.Fatalf("response should explain no speech, got %s", rec.Body.String())
	}
}

func writeCodexAuthFile(t *testing.T, accessToken string, accountID string) string {
	t.Helper()
	path := t.TempDir() + "/auth.json"
	raw, err := json.Marshal(map[string]any{
		"auth_mode": "chatgpt",
		"tokens": map[string]any{
			"access_token": accessToken,
			"account_id":   accountID,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

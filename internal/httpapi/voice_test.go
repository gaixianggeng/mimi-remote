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

func TestVoiceTranscribeHandlerRequiresAPIKeyWhenOpenAIProvider(t *testing.T) {
	router := &Router{cfg: config.Config{
		Voice: config.VoiceConfig{TranscriptionProvider: "openai"},
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
	if !strings.Contains(rec.Body.String(), "API Key") {
		t.Fatalf("response should explain missing API key, got %s", rec.Body.String())
	}
}

func TestVoiceTranscribeHandlerAutoDoesNotUseCodexLogin(t *testing.T) {
	router := &Router{cfg: config.Config{
		Voice: config.VoiceConfig{
			TranscriptionProvider: "auto",
			// 即使配置了登录态文件，auto 也不能隐式进入非公开 Codex 转写链路。
			CodexAuthFile: filepath.Join(t.TempDir(), "auth.json"),
		},
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
	if !strings.Contains(rec.Body.String(), "API Key") {
		t.Fatalf("auto 应提示配置公开 API Key，而不是读取 Codex 登录态：%s", rec.Body.String())
	}
}

func TestVoiceTranscribeHandlerPostsMultipartToOpenAIService(t *testing.T) {
	var sawRequest bool
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		sawRequest = true
		if req.Method != http.MethodPost {
			t.Fatalf("method = %s, want POST", req.Method)
		}
		if req.URL.Path != "/audio/transcriptions" {
			t.Fatalf("path = %s, want /audio/transcriptions", req.URL.Path)
		}
		if got := req.Header.Get("Authorization"); got != "Bearer test-key" {
			t.Fatalf("authorization = %q", got)
		}
		if err := req.ParseMultipartForm(16 << 20); err != nil {
			t.Fatal(err)
		}
		if got := req.FormValue("model"); got != "gpt-4o-mini-transcribe" {
			t.Fatalf("model = %q", got)
		}
		if got := req.FormValue("response_format"); got != "json" {
			t.Fatalf("response_format = %q", got)
		}
		if got := req.FormValue("language"); got != "zh" {
			t.Fatalf("language = %q", got)
		}
		if got := req.FormValue("prompt"); !strings.Contains(got, "中文") {
			t.Fatalf("prompt = %q", got)
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
		writeJSON(w, http.StatusOK, map[string]string{"text": "整理后的文字"})
	}))
	defer upstream.Close()

	router := &Router{cfg: config.Config{
		Voice: config.VoiceConfig{
			TranscriptionProvider: "openai",
			TranscriptionAPIKey:   "test-key",
			TranscriptionBaseURL:  upstream.URL,
			TranscriptionModel:    "gpt-4o-mini-transcribe",
		},
	}}
	body := voiceTranscriptionRequest{
		Filename:    "clip.m4a",
		ContentType: "audio/mp4",
		AudioBase64: base64.StdEncoding.EncodeToString([]byte("fake audio")),
		Language:    "zh_CN",
		Prompt:      "请按中文口语转写。",
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
	if response.Text != "整理后的文字" {
		t.Fatalf("text = %q", response.Text)
	}
	if response.Model != "gpt-4o-mini-transcribe" {
		t.Fatalf("model = %q", response.Model)
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
		if got := req.FormValue("model"); got != "" {
			t.Fatalf("codex /transcribe 不应发送公开 API model 字段，got %q", got)
		}
		if got := req.FormValue("response_format"); got != "" {
			t.Fatalf("codex /transcribe 不应发送 response_format 字段，got %q", got)
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
			TranscriptionProvider:     "codex",
			CodexTranscriptionBaseURL: upstream.URL,
			CodexAuthFile:             authFile,
		},
	}}
	body := voiceTranscriptionRequest{
		Filename:    "clip.m4a",
		ContentType: "audio/mp4",
		AudioBase64: base64.StdEncoding.EncodeToString([]byte("fake audio")),
		Language:    "zh_CN",
		Prompt:      "这个字段只给 OpenAI API 使用，Codex /transcribe 不发送。",
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
			TranscriptionProvider:     "codex",
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

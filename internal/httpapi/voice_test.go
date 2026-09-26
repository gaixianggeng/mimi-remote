package httpapi

import (
	"bytes"
	"context"
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
		AppServer: config.AppServerConfig{Transport: "local", SharedCodexHome: t.TempDir()},
		Voice:     config.VoiceConfig{CodexAuthFile: filepath.Join(t.TempDir(), "missing-auth.json")},
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
	if strings.Contains(rec.Body.String(), "Mimi Remote Mac") {
		t.Fatalf("显式 voice 凭据不能误指向共享目录登录：%s", rec.Body.String())
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

func TestCodexVoiceAuthUsesSharedBackendHome(t *testing.T) {
	publicHome := t.TempDir()
	backendHome := t.TempDir()
	writeCodexAuthInHome(t, publicHome, "public-token", "public-account")
	writeCodexAuthInHome(t, backendHome, "backend-token", "backend-account")
	t.Setenv("CODEX_HOME", publicHome)

	router := &Router{cfg: config.Config{
		AppServer: config.AppServerConfig{Transport: "local", SharedCodexHome: backendHome},
	}}
	auth, err := router.loadCodexChatGPTAuth()
	if err != nil {
		t.Fatal(err)
	}
	if auth.AccessToken != "backend-token" || auth.AccountID != "backend-account" {
		t.Fatalf("语音应使用共享 backend 登录态：%+v", auth)
	}
}

func TestCodexVoiceAuthExplicitFileOverridesSharedBackend(t *testing.T) {
	backendHome := t.TempDir()
	writeCodexAuthInHome(t, backendHome, "backend-token", "backend-account")
	explicitAuth := writeCodexAuthFile(t, "explicit-token", "explicit-account")
	router := &Router{cfg: config.Config{
		AppServer: config.AppServerConfig{Transport: "local", SharedCodexHome: backendHome},
		Voice:     config.VoiceConfig{CodexAuthFile: explicitAuth},
	}}

	auth, err := router.loadCodexChatGPTAuth()
	if err != nil {
		t.Fatal(err)
	}
	if auth.AccessToken != "explicit-token" || auth.AccountID != "explicit-account" {
		t.Fatalf("显式 voice.codex_auth_file 应保持最高优先级：%+v", auth)
	}
}

func TestCodexVoiceAuthKeepsProcessFallbackForSSH(t *testing.T) {
	publicHome := t.TempDir()
	sharedHome := t.TempDir()
	writeCodexAuthInHome(t, publicHome, "public-token", "public-account")
	writeCodexAuthInHome(t, sharedHome, "shared-token", "shared-account")
	t.Setenv("CODEX_HOME", publicHome)
	router := &Router{cfg: config.Config{
		AppServer: config.AppServerConfig{Transport: "ssh", SharedCodexHome: sharedHome},
	}}

	auth, err := router.loadCodexChatGPTAuth()
	if err != nil {
		t.Fatal(err)
	}
	if auth.AccessToken != "public-token" || auth.AccountID != "public-account" {
		t.Fatalf("SSH 语音应保留原本机登录态 fallback：%+v", auth)
	}
}

func TestCodexVoiceAuthSharedHomeErrorsUseMacLoginCommand(t *testing.T) {
	for _, tc := range []struct {
		name  string
		token string
	}{
		{name: "missing"},
		{name: "expired", token: "header." + base64.RawURLEncoding.EncodeToString([]byte(`{"exp":1}`)) + ".signature"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			sharedHome := t.TempDir()
			if tc.token != "" {
				writeCodexAuthInHome(t, sharedHome, tc.token, "account")
			}
			router := &Router{cfg: config.Config{
				AppServer: config.AppServerConfig{Transport: "local", SharedCodexHome: sharedHome},
			}}
			_, err := router.loadCodexChatGPTAuth()
			if err == nil || !strings.Contains(err.Error(), "Mimi Remote Mac") || !strings.Contains(err.Error(), "共享目录") {
				t.Fatalf("共享登录态错误应指向 Mac 详情中的正确命令：%v", err)
			}
			if strings.Contains(err.Error(), "codex login") || strings.Contains(err.Error(), "Codex Desktop") {
				t.Fatalf("共享登录态错误不能继续提示公共目录登录：%v", err)
			}
		})
	}
}

func TestCodexVoiceUnauthorizedSharedHomeUsesMacLoginCommand(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		writeError(w, http.StatusUnauthorized, "expired")
	}))
	defer upstream.Close()
	sharedHome := t.TempDir()
	writeCodexAuthInHome(t, sharedHome, "valid-token", "account")
	router := &Router{cfg: config.Config{
		AppServer: config.AppServerConfig{Transport: "local", SharedCodexHome: sharedHome},
		Voice:     config.VoiceConfig{CodexTranscriptionBaseURL: upstream.URL},
	}}
	_, err := router.createVoiceTranscription(context.Background(), voiceTranscriptionRequest{Filename: "clip.m4a"}, []byte("audio"))
	if err == nil || !strings.Contains(err.Error(), "Mimi Remote Mac") || !strings.Contains(err.Error(), "共享目录") {
		t.Fatalf("失效的共享登录态应指向 Mac 详情中的正确命令：%v", err)
	}
}

func writeCodexAuthFile(t *testing.T, accessToken string, accountID string) string {
	t.Helper()
	path := t.TempDir() + "/auth.json"
	writeCodexAuth(t, path, accessToken, accountID)
	return path
}

func writeCodexAuthInHome(t *testing.T, home string, accessToken string, accountID string) {
	t.Helper()
	writeCodexAuth(t, filepath.Join(home, "auth.json"), accessToken, accountID)
}

func writeCodexAuth(t *testing.T, path string, accessToken string, accountID string) {
	t.Helper()
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
}

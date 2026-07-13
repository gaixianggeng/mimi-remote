package httpapi

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const voiceTranscriptionMaxBytes = 12 << 20
const codexVoiceTranscriptionModel = "codex-session-transcribe"

type voiceTranscriptionRequest struct {
	Filename    string `json:"filename"`
	ContentType string `json:"content_type"`
	AudioBase64 string `json:"audio_base64"`
	Language    string `json:"language,omitempty"`
	Prompt      string `json:"prompt,omitempty"`
}

type voiceTranscriptionResponse struct {
	Text  string `json:"text"`
	Model string `json:"model"`
}

type voiceTranscriptionResult struct {
	Text  string
	Model string
}

func (r *Router) voiceTranscribeHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}

	var payload voiceTranscriptionRequest
	if !decodeJSONRequest(w, req, &payload) {
		return
	}
	audio, err := decodeVoiceAudio(payload.AudioBase64)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	ctx, cancel := context.WithTimeout(req.Context(), 45*time.Second)
	defer cancel()
	result, err := r.createVoiceTranscription(ctx, payload, audio)
	if err != nil {
		status := http.StatusBadGateway
		if isVoiceConfigurationError(err) {
			status = http.StatusServiceUnavailable
		} else if isVoiceNoSpeechError(err) {
			status = http.StatusUnprocessableEntity
		}
		writeError(w, status, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, voiceTranscriptionResponse{
		Text:  strings.TrimSpace(result.Text),
		Model: firstNonEmpty(result.Model, r.voiceTranscriptionModel()),
	})
}

func decodeVoiceAudio(raw string) ([]byte, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return nil, fmt.Errorf("audio_base64 不能为空")
	}
	audio, err := base64.StdEncoding.DecodeString(trimmed)
	if err != nil {
		return nil, fmt.Errorf("audio_base64 不是合法 base64")
	}
	if len(audio) == 0 {
		return nil, fmt.Errorf("音频内容为空")
	}
	if len(audio) > voiceTranscriptionMaxBytes {
		return nil, fmt.Errorf("音频过大，最长支持约 12MB")
	}
	return audio, nil
}

func (r *Router) createVoiceTranscription(ctx context.Context, payload voiceTranscriptionRequest, audio []byte) (voiceTranscriptionResult, error) {
	provider := r.voiceTranscriptionProvider()
	// auto 只保留为旧配置兼容别名，并始终走公开 API。只有显式选择 codex，
	// 才允许读取本机登录态并调用未公开的 ChatGPT 转写接口。
	if provider == "openai" || provider == "auto" {
		return r.createOpenAIVoiceTranscription(ctx, payload, audio)
	}
	if provider == "codex" {
		return r.createCodexVoiceTranscription(ctx, payload, audio)
	}
	return voiceTranscriptionResult{}, fmt.Errorf("未知语音转写 provider：%s", provider)
}

func (r *Router) createOpenAIVoiceTranscription(ctx context.Context, payload voiceTranscriptionRequest, audio []byte) (voiceTranscriptionResult, error) {
	if strings.TrimSpace(r.cfg.Voice.TranscriptionAPIKey) == "" {
		return voiceTranscriptionResult{}, fmt.Errorf("未配置语音转写 API Key，请在 agentd 设置 OPENAI_API_KEY 或 AGENTD_TRANSCRIPTION_API_KEY")
	}
	fields := map[string]string{
		"model":           r.voiceTranscriptionModel(),
		"response_format": "json",
	}
	// gpt-4o-transcribe 系列只稳定支持 JSON 响应；agentd 解析后再返回给 iPad。
	if language := normalizedVoiceLanguage(payload.Language); language != "" {
		fields["language"] = language
	}
	if prompt := strings.TrimSpace(payload.Prompt); prompt != "" {
		fields["prompt"] = prompt
	}
	body, contentType, err := buildVoiceMultipart(payload, audio, fields)
	if err != nil {
		return voiceTranscriptionResult{}, err
	}

	url := strings.TrimRight(firstNonEmpty(r.cfg.Voice.TranscriptionBaseURL, "https://api.openai.com/v1"), "/") + "/audio/transcriptions"
	outbound, err := http.NewRequestWithContext(ctx, http.MethodPost, url, body)
	if err != nil {
		return voiceTranscriptionResult{}, err
	}
	outbound.Header.Set("Authorization", "Bearer "+strings.TrimSpace(r.cfg.Voice.TranscriptionAPIKey))
	outbound.Header.Set("Content-Type", contentType)
	response, err := http.DefaultClient.Do(outbound)
	if err != nil {
		return voiceTranscriptionResult{}, fmt.Errorf("语音转写请求失败：%w", err)
	}
	defer response.Body.Close()
	responseBody, _ := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return voiceTranscriptionResult{}, fmt.Errorf("语音转写服务返回 HTTP %d：%s", response.StatusCode, voiceServiceError(responseBody))
	}
	var decoded struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal(responseBody, &decoded); err != nil {
		return voiceTranscriptionResult{}, fmt.Errorf("语音转写响应不是合法 JSON")
	}
	text := strings.TrimSpace(decoded.Text)
	if text == "" {
		return voiceTranscriptionResult{}, fmt.Errorf("语音转写结果为空")
	}
	return voiceTranscriptionResult{Text: text, Model: r.voiceTranscriptionModel()}, nil
}

func (r *Router) createCodexVoiceTranscription(ctx context.Context, payload voiceTranscriptionRequest, audio []byte) (voiceTranscriptionResult, error) {
	auth, err := r.loadCodexChatGPTAuth()
	if err != nil {
		return voiceTranscriptionResult{}, err
	}
	fields := map[string]string{}
	if language := normalizedVoiceLanguage(payload.Language); language != "" {
		fields["language"] = language
	}
	body, contentType, err := buildVoiceMultipart(payload, audio, fields)
	if err != nil {
		return voiceTranscriptionResult{}, err
	}

	url := strings.TrimRight(firstNonEmpty(r.cfg.Voice.CodexTranscriptionBaseURL, "https://chatgpt.com/backend-api"), "/") + "/transcribe"
	outbound, err := http.NewRequestWithContext(ctx, http.MethodPost, url, body)
	if err != nil {
		return voiceTranscriptionResult{}, err
	}
	outbound.Header.Set("Authorization", "Bearer "+auth.AccessToken)
	if auth.AccountID != "" {
		outbound.Header.Set("ChatGPT-Account-Id", auth.AccountID)
	}
	// Codex Desktop 自带语音使用 ChatGPT 后端的 /transcribe；这些 surface 头是该后端识别桌面请求的关键。
	outbound.Header.Set("originator", "Codex Desktop")
	outbound.Header.Set("OAI-Product-Sku", "CODEX")
	outbound.Header.Set("User-Agent", codexDesktopUserAgent())
	outbound.Header.Set("Content-Type", contentType)

	response, err := http.DefaultClient.Do(outbound)
	if err != nil {
		return voiceTranscriptionResult{}, fmt.Errorf("Codex 登录态语音转写请求失败：%w", err)
	}
	defer response.Body.Close()
	responseBody, _ := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		if response.StatusCode == http.StatusUnauthorized {
			return voiceTranscriptionResult{}, fmt.Errorf("Codex 登录态已失效，请先在 Mac 上运行 codex login 或打开 Codex Desktop 重新登录")
		}
		return voiceTranscriptionResult{}, fmt.Errorf("Codex 登录态语音转写返回 HTTP %d：%s", response.StatusCode, voiceServiceError(responseBody))
	}
	var decoded struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal(responseBody, &decoded); err != nil {
		return voiceTranscriptionResult{}, fmt.Errorf("Codex 登录态语音转写响应不是合法 JSON")
	}
	text := strings.TrimSpace(decoded.Text)
	if text == "" {
		log.Printf("voice transcription empty provider=codex audio_bytes=%d filename=%s content_type=%s language=%s response_keys=%v", len(audio), filepath.Base(payload.Filename), payload.ContentType, normalizedVoiceLanguage(payload.Language), jsonObjectKeys(responseBody))
		return voiceTranscriptionResult{}, fmt.Errorf("没有识别到语音内容，请按住说话至少 1 秒，并确认麦克风靠近说话人")
	}
	return voiceTranscriptionResult{Text: text, Model: codexVoiceTranscriptionModel}, nil
}

func buildVoiceMultipart(payload voiceTranscriptionRequest, audio []byte, fields map[string]string) (*bytes.Buffer, string, error) {
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	for key, value := range fields {
		if strings.TrimSpace(value) == "" {
			continue
		}
		if err := writer.WriteField(key, value); err != nil {
			return nil, "", err
		}
	}
	fileWriter, err := writer.CreatePart(voiceFileHeader(payload))
	if err != nil {
		return nil, "", err
	}
	if _, err := fileWriter.Write(audio); err != nil {
		return nil, "", err
	}
	if err := writer.Close(); err != nil {
		return nil, "", err
	}
	return &body, writer.FormDataContentType(), nil
}

type codexChatGPTAuth struct {
	AccessToken string
	AccountID   string
}

func (r *Router) loadCodexChatGPTAuth() (codexChatGPTAuth, error) {
	authFile := codexAuthFilePath(r.cfg.Voice.CodexAuthFile)
	data, err := os.ReadFile(authFile)
	if err != nil {
		return codexChatGPTAuth{}, fmt.Errorf("未找到 Codex 登录态，请先在 Mac 上运行 codex login 或打开 Codex Desktop 登录：%w", err)
	}
	var decoded struct {
		AuthMode string `json:"auth_mode"`
		Tokens   struct {
			AccessToken string `json:"access_token"`
			AccountID   string `json:"account_id"`
		} `json:"tokens"`
	}
	if err := json.Unmarshal(data, &decoded); err != nil {
		return codexChatGPTAuth{}, fmt.Errorf("Codex 登录态文件不是合法 JSON")
	}
	if !strings.EqualFold(strings.TrimSpace(decoded.AuthMode), "chatgpt") {
		return codexChatGPTAuth{}, fmt.Errorf("当前 Codex 不是 ChatGPT 登录模式，无法免 API key 使用内置语音转写")
	}
	token := strings.TrimSpace(decoded.Tokens.AccessToken)
	if token == "" {
		return codexChatGPTAuth{}, fmt.Errorf("Codex 登录态缺少 access_token，请重新登录 Codex")
	}
	if exp, ok := jwtExpiry(token); ok && time.Now().After(exp) {
		return codexChatGPTAuth{}, fmt.Errorf("Codex 登录态已过期，请在 Mac 上运行 codex login status 或重新登录 Codex")
	}
	accountID := firstNonEmpty(strings.TrimSpace(decoded.Tokens.AccountID), chatGPTAccountIDFromJWT(token))
	return codexChatGPTAuth{AccessToken: token, AccountID: accountID}, nil
}

func (r *Router) voiceTranscriptionProvider() string {
	switch strings.ToLower(strings.TrimSpace(r.cfg.Voice.TranscriptionProvider)) {
	case "", "auto":
		return "auto"
	case "codex":
		return "codex"
	case "openai":
		return "openai"
	default:
		return strings.ToLower(strings.TrimSpace(r.cfg.Voice.TranscriptionProvider))
	}
}

func (r *Router) voiceTranscriptionModel() string {
	return firstNonEmpty(r.cfg.Voice.TranscriptionModel, "gpt-4o-mini-transcribe")
}

func voiceFileHeader(payload voiceTranscriptionRequest) textproto.MIMEHeader {
	filename := strings.TrimSpace(payload.Filename)
	if filename == "" {
		filename = "voice.m4a"
	}
	filename = filepath.Base(filename)
	contentType := strings.TrimSpace(payload.ContentType)
	if contentType == "" {
		contentType = contentTypeForAudioFilename(filename)
	}
	header := make(textproto.MIMEHeader)
	header.Set("Content-Disposition", fmt.Sprintf(`form-data; name="file"; filename="%s"`, escapeMultipartFilename(filename)))
	header.Set("Content-Type", contentType)
	return header
}

func contentTypeForAudioFilename(filename string) string {
	switch strings.ToLower(filepath.Ext(filename)) {
	case ".m4a", ".mp4":
		return "audio/mp4"
	case ".mp3", ".mpeg", ".mpga":
		return "audio/mpeg"
	case ".wav":
		return "audio/wav"
	case ".ogg":
		return "audio/ogg"
	case ".webm":
		return "audio/webm"
	case ".flac":
		return "audio/flac"
	default:
		return "audio/mp4"
	}
}

func escapeMultipartFilename(filename string) string {
	return strings.NewReplacer("\\", "\\\\", `"`, "\\\"").Replace(filename)
}

func normalizedVoiceLanguage(raw string) string {
	value := strings.TrimSpace(strings.ToLower(raw))
	switch value {
	case "", "auto", "automatic":
		return ""
	case "zh", "zh-cn", "zh_cn", "chinese", "chinese_simplified":
		return "zh"
	case "en", "en-us", "en_us", "english":
		return "en"
	case "ja", "ja-jp", "ja_jp", "japanese":
		return "ja"
	case "ko", "ko-kr", "ko_kr", "korean":
		return "ko"
	default:
		if len(value) == 2 {
			return value
		}
		return ""
	}
}

func codexAuthFilePath(configured string) string {
	if path := expandHomePath(strings.TrimSpace(configured)); path != "" {
		return path
	}
	if codexHome := expandHomePath(strings.TrimSpace(os.Getenv("CODEX_HOME"))); codexHome != "" {
		return filepath.Join(codexHome, "auth.json")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(".codex", "auth.json")
	}
	return filepath.Join(home, ".codex", "auth.json")
}

func expandHomePath(path string) string {
	if path == "" || !strings.HasPrefix(path, "~/") {
		return path
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return path
	}
	return filepath.Join(home, strings.TrimPrefix(path, "~/"))
}

func codexDesktopUserAgent() string {
	osName := runtime.GOOS
	switch runtime.GOOS {
	case "darwin":
		osName = "Mac OS"
	case "linux":
		osName = "X11; Linux"
	case "windows":
		osName = "Windows NT 10.0"
	}
	return fmt.Sprintf("Codex Desktop/agentd (%s; %s)", osName, runtime.GOARCH)
}

func chatGPTAccountIDFromJWT(token string) string {
	payload, ok := jwtPayload(token)
	if !ok {
		return ""
	}
	auth, ok := payload["https://api.openai.com/auth"].(map[string]any)
	if !ok {
		return ""
	}
	accountID, _ := auth["chatgpt_account_id"].(string)
	return strings.TrimSpace(accountID)
}

func jwtExpiry(token string) (time.Time, bool) {
	payload, ok := jwtPayload(token)
	if !ok {
		return time.Time{}, false
	}
	exp, ok := payload["exp"].(float64)
	if !ok || exp <= 0 {
		return time.Time{}, false
	}
	return time.Unix(int64(exp), 0), true
}

func jwtPayload(token string) (map[string]any, bool) {
	parts := strings.Split(token, ".")
	if len(parts) < 2 {
		return nil, false
	}
	data, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, false
	}
	var payload map[string]any
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, false
	}
	return payload, true
}

func voiceServiceError(data []byte) string {
	var decoded struct {
		Error any `json:"error"`
	}
	if err := json.Unmarshal(data, &decoded); err == nil && decoded.Error != nil {
		switch typed := decoded.Error.(type) {
		case string:
			return typed
		case map[string]any:
			if message, ok := typed["message"].(string); ok && strings.TrimSpace(message) != "" {
				return message
			}
		}
	}
	text := strings.TrimSpace(string(data))
	if text == "" {
		return "空响应"
	}
	return text
}

func jsonObjectKeys(data []byte) []string {
	var decoded map[string]any
	if err := json.Unmarshal(data, &decoded); err != nil {
		return nil
	}
	keys := make([]string, 0, len(decoded))
	for key := range decoded {
		keys = append(keys, key)
	}
	return keys
}

func isVoiceConfigurationError(err error) bool {
	if err == nil {
		return false
	}
	message := err.Error()
	return strings.Contains(message, "未配置语音转写 API Key") ||
		strings.Contains(message, "未找到 Codex 登录态") ||
		strings.Contains(message, "当前 Codex 不是 ChatGPT 登录模式") ||
		strings.Contains(message, "Codex 登录态缺少") ||
		strings.Contains(message, "Codex 登录态已过期") ||
		strings.Contains(message, "Codex 登录态已失效")
}

func isVoiceNoSpeechError(err error) bool {
	return err != nil && strings.Contains(err.Error(), "没有识别到语音内容")
}

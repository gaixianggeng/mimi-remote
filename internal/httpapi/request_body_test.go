package httpapi

import (
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

type requestBodyTestPayload struct {
	Value string `json:"value"`
}

func TestAPIRequestBodyLimitsAreTieredForPairingAndVoice(t *testing.T) {
	if got := requestBodyLimitForPath("/api/pair/claim"); got != pairingRequestBodyMaxBytes || got >= defaultAPIRequestBodyMaxBytes {
		t.Fatalf("未鉴权 pairing 应使用更小上限：%d", got)
	}
	if got := requestBodyLimitForPath("/api/workspaces/resolve"); got != defaultAPIRequestBodyMaxBytes {
		t.Fatalf("普通 JSON API 应使用统一默认上限：%d", got)
	}
	if got := requestBodyLimitForPath("/api/voice/transcribe"); got != voiceRequestBodyMaxBytes || got <= defaultAPIRequestBodyMaxBytes {
		t.Fatalf("voice 应使用独立大 body 上限：%d", got)
	}
	// 12 MiB 原始音频的完整 base64 字符串必须仍能装进 voice JSON envelope。
	encodedAudioBytes := int64(base64.StdEncoding.EncodedLen(int(voiceTranscriptionMaxBytes)))
	jsonEnvelopeBytes := int64(len(`{"audio_base64":""}`))
	if encodedAudioBytes+jsonEnvelopeBytes > voiceRequestBodyMaxBytes {
		t.Fatalf("voice body 上限会误伤 12 MiB 合法音频：encoded=%d envelope=%d limit=%d", encodedAudioBytes, jsonEnvelopeBytes, voiceRequestBodyMaxBytes)
	}
}

func TestRequestBodyLimitRejectsKnownOversizeBeforeHandler(t *testing.T) {
	var called atomic.Bool
	handler := limitAPIRequestBodies(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		called.Store(true)
		w.WriteHeader(http.StatusNoContent)
	}))
	req := httptest.NewRequest(http.MethodPost, "/api/pair/claim", strings.NewReader("{}"))
	req.ContentLength = pairingRequestBodyMaxBytes + 1
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("已知 Content-Length 超限应直接返回 413：code=%d body=%s", rec.Code, rec.Body.String())
	}
	if called.Load() {
		t.Fatal("超限请求不应进入业务 handler")
	}
}

func TestPairingClaimRejectsOversizedKnownAndChunkedBodies(t *testing.T) {
	for _, mode := range []string{"content-length", "chunked"} {
		t.Run(mode, func(t *testing.T) {
			server := newTestServer(t)
			secretMarker := "must-not-be-reflected"
			body := `{"endpoint":"` + secretMarker + strings.Repeat("x", int(pairingRequestBodyMaxBytes)) + `"}`
			req := httptest.NewRequest(http.MethodPost, "/api/pair/claim", strings.NewReader(body))
			if mode == "chunked" {
				req.ContentLength = -1
			}
			rec := httptest.NewRecorder()

			server.handler.ServeHTTP(rec, req)

			if rec.Code != http.StatusRequestEntityTooLarge {
				t.Fatalf("未鉴权 pairing 超限必须返回 413：code=%d body=%s", rec.Code, rec.Body.String())
			}
			if !strings.Contains(rec.Body.String(), "请求体过大") || strings.Contains(rec.Body.String(), secretMarker) {
				t.Fatalf("超限响应应为中文通用错误且不得回显请求内容：%s", rec.Body.String())
			}
		})
	}
}

func TestAuthenticatedJSONHandlerRejectsChunkedOversizeBody(t *testing.T) {
	server := newTestServer(t)
	body := `{"path":"` + strings.Repeat("x", int(defaultAPIRequestBodyMaxBytes)) + `"}`
	req := httptest.NewRequest(http.MethodPost, "/api/workspaces/resolve", strings.NewReader(body))
	req.ContentLength = -1
	req.Header.Set("Authorization", "Bearer "+testToken)
	rec := httptest.NewRecorder()

	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("普通 JSON API 的 chunked 超限请求必须返回 413：code=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestVoiceRouteAllowsJSONBodyAboveDefaultLimit(t *testing.T) {
	handler := limitAPIRequestBodies(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		var payload requestBodyTestPayload
		if !decodeJSONRequest(w, req, &payload) {
			return
		}
		if len(payload.Value) <= int(defaultAPIRequestBodyMaxBytes) {
			t.Errorf("测试负载没有超过默认上限：%d", len(payload.Value))
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	body := `{"value":"` + strings.Repeat("a", int(defaultAPIRequestBodyMaxBytes)+1024) + `"}`
	req := httptest.NewRequest(http.MethodPost, "/api/voice/transcribe", strings.NewReader(body))
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("voice 合法大 JSON 不应被默认小上限误伤：code=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestJSONDecoderReadsTrailingDataAndRejectsOversizePadding(t *testing.T) {
	handler := limitAPIRequestBodies(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		var payload requestBodyTestPayload
		if !decodeJSONRequest(w, req, &payload) {
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	body := `{"value":"ok"}` + strings.Repeat(" ", int(defaultAPIRequestBodyMaxBytes))
	req := httptest.NewRequest(http.MethodPost, "/api/test", strings.NewReader(body))
	req.ContentLength = -1
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("合法 JSON 后追加超限 padding 也必须返回 413：code=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestJSONDecoderRejectsMultipleValues(t *testing.T) {
	handler := limitAPIRequestBodies(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		var payload requestBodyTestPayload
		if !decodeJSONRequest(w, req, &payload) {
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	req := httptest.NewRequest(http.MethodPost, "/api/test", strings.NewReader(`{"value":"first"} {"value":"second"}`))
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "只能包含一个 JSON 值") {
		t.Fatalf("多个 JSON 值必须被拒绝：code=%d body=%s", rec.Code, rec.Body.String())
	}
}

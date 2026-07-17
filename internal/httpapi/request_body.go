package httpapi

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
)

const (
	// 默认 JSON 请求只承载路径、动作 ID 和少量文本；256 KiB 足以覆盖 64 KiB Git hunk 等现有合法负载。
	defaultAPIRequestBodyMaxBytes int64 = 256 << 10
	// pairing 未鉴权且只需要四个短字段，使用更小上限降低公网/LAN 垃圾请求的资源占用。
	pairingRequestBodyMaxBytes int64 = 16 << 10
	// 12 MiB 原始音频经过 base64 后约 16 MiB，再预留 1 MiB 给 JSON、文件名、语言和 prompt。
	voiceRequestBodyMaxBytes int64 = 17 << 20
)

func limitAPIRequestBodies(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		limit := requestBodyLimitForPath(req.URL.Path)
		if req.ContentLength > limit {
			writeError(w, http.StatusRequestEntityTooLarge, "请求体过大")
			return
		}
		if req.Body != nil {
			// MaxBytesReader 同时覆盖 Content-Length 缺失/伪造和 chunked body；超过上限后最多再读取一个字节即停止。
			req.Body = http.MaxBytesReader(w, req.Body, limit)
		}
		next.ServeHTTP(w, req)
	})
}

func requestBodyLimitForPath(path string) int64 {
	switch path {
	case "/api/pair/claim", "/api/pair/local":
		return pairingRequestBodyMaxBytes
	case "/api/voice/transcribe":
		return voiceRequestBodyMaxBytes
	default:
		return defaultAPIRequestBodyMaxBytes
	}
}

func decodeJSONRequest(w http.ResponseWriter, req *http.Request, target any) bool {
	decoder := json.NewDecoder(req.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		writeJSONDecodeError(w, err)
		return false
	}
	// 强制读到 EOF，既拒绝第二个 JSON 值/畸形尾部，也让 chunked 超限请求可靠触发 MaxBytesError。
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			writeError(w, http.StatusBadRequest, "请求体只能包含一个 JSON 值")
			return false
		}
		writeJSONDecodeError(w, err)
		return false
	}
	return true
}

func writeJSONDecodeError(w http.ResponseWriter, err error) {
	var maxBytesError *http.MaxBytesError
	if errors.As(err, &maxBytesError) {
		writeError(w, http.StatusRequestEntityTooLarge, "请求体过大")
		return
	}
	writeError(w, http.StatusBadRequest, "请求体不是合法 JSON")
}

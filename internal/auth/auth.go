package auth

import (
	"crypto/subtle"
	"encoding/json"
	"net/http"
	"strings"
)

type Authenticator struct {
	token      string
	devNoAuth  bool
	allowQuery bool
}

type Options struct {
	AllowQueryToken bool
}

func New(token string, devNoAuth bool) Authenticator {
	return NewWithOptions(token, devNoAuth, Options{})
}

func NewWithOptions(token string, devNoAuth bool, options Options) Authenticator {
	return Authenticator{token: token, devNoAuth: devNoAuth, allowQuery: options.AllowQueryToken}
}

func (a Authenticator) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !a.ValidRequest(r) {
			w.Header().Set("WWW-Authenticate", "Bearer")
			w.Header().Set("Content-Type", "application/json; charset=utf-8")
			w.WriteHeader(http.StatusUnauthorized)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "unauthorized"})
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (a Authenticator) ValidRequest(r *http.Request) bool {
	if a.devNoAuth {
		return true
	}
	got := bearerToken(r.Header.Get("Authorization"))
	if got == "" && a.allowQuery {
		got = r.URL.Query().Get("token")
	}
	return a.ValidToken(got)
}

func (a Authenticator) ValidToken(got string) bool {
	if a.token == "" || got == "" {
		return false
	}
	// 使用常量时间比较，避免通过响应时间猜测 token。
	return subtle.ConstantTimeCompare([]byte(got), []byte(a.token)) == 1
}

func bearerToken(raw string) string {
	if raw == "" {
		return ""
	}
	parts := strings.SplitN(raw, " ", 2)
	if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") {
		return ""
	}
	return strings.TrimSpace(parts[1])
}

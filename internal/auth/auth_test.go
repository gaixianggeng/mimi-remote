package auth

import (
	"net/http"
	"testing"
)

func TestAuthenticatorValidBearerToken(t *testing.T) {
	a := New("0123456789abcdef0123456789abcdef", false)
	req, err := http.NewRequest(http.MethodGet, "/api/projects", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer 0123456789abcdef0123456789abcdef")
	if !a.ValidRequest(req) {
		t.Fatal("期望合法 token 通过校验")
	}
}

func TestAuthenticatorRejectsWrongToken(t *testing.T) {
	a := New("0123456789abcdef0123456789abcdef", false)
	req, err := http.NewRequest(http.MethodGet, "/api/projects?token=bad-token", nil)
	if err != nil {
		t.Fatal(err)
	}
	if a.ValidRequest(req) {
		t.Fatal("期望错误 token 被拒绝")
	}
}

func TestAuthenticatorRejectsQueryTokenByDefault(t *testing.T) {
	a := New("0123456789abcdef0123456789abcdef", false)
	req, err := http.NewRequest(http.MethodGet, "/api/projects?token=0123456789abcdef0123456789abcdef", nil)
	if err != nil {
		t.Fatal(err)
	}
	if a.ValidRequest(req) {
		t.Fatal("默认不应接受 query token，避免 URL 和日志泄漏凭证")
	}
}

func TestAuthenticatorCanAllowQueryTokenForBrowserCompatibility(t *testing.T) {
	a := NewWithOptions("0123456789abcdef0123456789abcdef", false, Options{AllowQueryToken: true})
	req, err := http.NewRequest(http.MethodGet, "/api/projects?token=0123456789abcdef0123456789abcdef", nil)
	if err != nil {
		t.Fatal(err)
	}
	if !a.ValidRequest(req) {
		t.Fatal("显式兼容模式应允许 query token")
	}
}

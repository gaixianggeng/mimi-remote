package httpapi

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/auth"
)

func TestPairingClaimConsumesOnlyValidatedTicketAndRejectsReplay(t *testing.T) {
	server := newTestServer(t)
	now := time.Now().UTC()
	ticket := auth.NewPairingTicket("http://100.64.0.1:8787", testToken, now.Add(-time.Minute), now.Add(9*time.Minute))
	payload := pairingClaimRequest{
		Endpoint:  ticket.Endpoint,
		IssuedAt:  ticket.IssuedAt,
		ExpiresAt: ticket.ExpiresAt,
		Signature: ticket.Signature,
	}

	invalid := payload
	invalid.Signature = strings.Repeat("0", len(ticket.Signature))
	invalidRequest := authedRequest(t, http.MethodPost, "/api/pair/claim", invalid)
	invalidRequest.Header.Del("Authorization")
	invalidResponse := httptest.NewRecorder()
	server.handler.ServeHTTP(invalidResponse, invalidRequest)
	if invalidResponse.Code != http.StatusUnauthorized {
		t.Fatalf("无效签名应先被拒绝，got=%d body=%s", invalidResponse.Code, invalidResponse.Body.String())
	}

	validRequest := authedRequest(t, http.MethodPost, "/api/pair/claim", payload)
	validRequest.Header.Del("Authorization")
	validResponse := httptest.NewRecorder()
	server.handler.ServeHTTP(validResponse, validRequest)
	if validResponse.Code != http.StatusOK {
		t.Fatalf("无效尝试不能提前消费合法票据，got=%d body=%s", validResponse.Code, validResponse.Body.String())
	}

	replayRequest := authedRequest(t, http.MethodPost, "/api/pair/claim", payload)
	replayRequest.Header.Del("Authorization")
	replayResponse := httptest.NewRecorder()
	server.handler.ServeHTTP(replayResponse, replayRequest)
	if replayResponse.Code != http.StatusConflict {
		t.Fatalf("重复兑换必须被拒绝，got=%d body=%s", replayResponse.Code, replayResponse.Body.String())
	}
	if strings.Contains(replayResponse.Body.String(), testToken) {
		t.Fatal("重复兑换响应不能泄漏长期 Token")
	}
}

func TestLocalPairingClaimOnlyReturnsTokenToNativeLoopbackRequest(t *testing.T) {
	server := newTestServer(t)

	validRequest := httptest.NewRequest(http.MethodPost, "http://127.0.0.1:8787/api/pair/local", nil)
	validRequest.RemoteAddr = "127.0.0.1:54321"
	validRequest.Header.Set(localPairingHeader, "1")
	validResponse := httptest.NewRecorder()
	server.handler.ServeHTTP(validResponse, validRequest)

	if validResponse.Code != http.StatusOK {
		t.Fatalf("原生 loopback 请求应可自动配对，got=%d body=%s", validResponse.Code, validResponse.Body.String())
	}
	var response pairingClaimResponse
	if err := json.NewDecoder(validResponse.Body).Decode(&response); err != nil {
		t.Fatalf("本机配对响应无法解码：%v", err)
	}
	if response.Endpoint != localPairingEndpoint || response.Token != testToken {
		t.Fatalf("本机配对响应异常：%+v", response)
	}

	tests := []struct {
		name       string
		remoteAddr string
		host       string
		header     string
		origin     string
	}{
		{name: "remote source", remoteAddr: "100.64.0.2:54321", host: "127.0.0.1:8787", header: "1"},
		{name: "non-loopback host", remoteAddr: "127.0.0.1:54321", host: "100.64.0.1:8787", header: "1"},
		{name: "missing native header", remoteAddr: "127.0.0.1:54321", host: "127.0.0.1:8787"},
		{name: "browser origin", remoteAddr: "127.0.0.1:54321", host: "127.0.0.1:8787", header: "1", origin: "https://example.com"},
	}
	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "http://"+testCase.host+"/api/pair/local", nil)
			req.RemoteAddr = testCase.remoteAddr
			if testCase.header != "" {
				req.Header.Set(localPairingHeader, testCase.header)
			}
			if testCase.origin != "" {
				req.Header.Set("Origin", testCase.origin)
			}
			rec := httptest.NewRecorder()
			server.handler.ServeHTTP(rec, req)

			if rec.Code != http.StatusForbidden {
				t.Fatalf("非可信本机请求必须被拒绝，got=%d body=%s", rec.Code, rec.Body.String())
			}
			if strings.Contains(rec.Body.String(), testToken) {
				t.Fatal("拒绝响应不能泄漏长期 Token")
			}
		})
	}
}

func TestConsumePairingTicketIsSingleUseUnderConcurrency(t *testing.T) {
	now := time.Date(2026, 7, 13, 8, 0, 0, 123, time.UTC)
	ticket := auth.NewPairingTicket("http://100.64.0.1:8787", testToken, now, now.Add(10*time.Minute))
	router := &Router{pairingClaims: map[string]time.Time{}}

	const attempts = 24
	var wait sync.WaitGroup
	results := make(chan error, attempts)
	for range attempts {
		wait.Add(1)
		go func() {
			defer wait.Done()
			results <- router.consumePairingTicket(ticket, now.Add(time.Second))
		}()
	}
	wait.Wait()
	close(results)

	succeeded := 0
	consumed := 0
	for err := range results {
		switch {
		case err == nil:
			succeeded++
		case errors.Is(err, errPairingTicketConsumed):
			consumed++
		default:
			t.Fatalf("并发兑换返回了非预期错误：%v", err)
		}
	}
	if succeeded != 1 || consumed != attempts-1 {
		t.Fatalf("并发兑换必须恰好成功一次，success=%d consumed=%d", succeeded, consumed)
	}
}

func TestConsumePairingTicketPrunesExpiredEntriesAndFailsClosedAtCapacity(t *testing.T) {
	now := time.Date(2026, 7, 13, 8, 0, 0, 0, time.UTC)
	router := &Router{pairingClaims: map[string]time.Time{"expired": now.Add(-time.Second)}}
	first := auth.NewPairingTicket("http://100.64.0.1:8787", testToken, now, now.Add(10*time.Minute))
	if err := router.consumePairingTicket(first, now); err != nil {
		t.Fatalf("过期记录应先清理：%v", err)
	}
	if _, exists := router.pairingClaims["expired"]; exists {
		t.Fatal("过期票据记录未清理")
	}

	for index := len(router.pairingClaims); index < maxConsumedPairingTickets; index++ {
		router.pairingClaims[fmt.Sprintf("used-%d", index)] = now.Add(time.Minute)
	}
	next := auth.NewPairingTicket("http://100.64.0.2:8787", testToken, now.Add(time.Nanosecond), now.Add(10*time.Minute))
	if err := router.consumePairingTicket(next, now); !errors.Is(err, errPairingClaimStoreFull) {
		t.Fatalf("容量满时必须 fail-closed，got=%v", err)
	}
	if len(router.pairingClaims) != maxConsumedPairingTickets {
		t.Fatalf("消费集合必须有界，got=%d", len(router.pairingClaims))
	}
}

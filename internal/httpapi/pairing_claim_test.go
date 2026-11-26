package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/auth"
	"github.com/gaixianggeng/mimi-remote/internal/tailscaleinfo"
)

func TestPairingClaimRejectsInvalidSignatureAndAllowsRepeatedValidClaims(t *testing.T) {
	tests := []struct {
		name     string
		endpoint string
	}{
		{name: "tailscale", endpoint: "http://100.64.0.1:8787"},
		{name: "lan", endpoint: "http://192.168.1.20:8787"},
	}
	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			server := newPairingTestServer(t)
			httpServer := httptest.NewServer(server.handler)
			t.Cleanup(httpServer.Close)
			now := time.Now().UTC()
			ticket := auth.NewPairingTicket(
				testCase.endpoint,
				testToken,
				now.Add(-time.Minute),
				now.Add(9*time.Minute),
			)
			payload := pairingClaimRequest{
				Endpoint:  ticket.Endpoint,
				IssuedAt:  ticket.IssuedAt,
				ExpiresAt: ticket.ExpiresAt,
				Signature: ticket.Signature,
			}

			invalid := payload
			invalid.Signature = strings.Repeat("0", len(ticket.Signature))
			invalidStatus, invalidBody := performPairingClaimOverHTTP(t, httpServer.URL, invalid)
			if invalidStatus != http.StatusUnauthorized {
				t.Fatalf(
					"无效签名应被拒绝，got=%d body=%s",
					invalidStatus,
					invalidBody,
				)
			}

			// 扫码与复制链接最终提交完全相同的票据字段；连续两次成功同时覆盖两种入口。
			for attempt := 1; attempt <= 2; attempt++ {
				status, body := performPairingClaimOverHTTP(t, httpServer.URL, payload)
				if status != http.StatusOK {
					t.Fatalf(
						"有效期内第 %d 次兑换应成功，got=%d body=%s",
						attempt,
						status,
						body,
					)
				}
				var claimed pairingClaimResponse
				if err := json.Unmarshal(body, &claimed); err != nil {
					t.Fatalf("第 %d 次响应无法解码：%v", attempt, err)
				}
				if claimed.Endpoint != testCase.endpoint || claimed.Token != testToken {
					t.Fatalf("第 %d 次兑换响应异常：%+v", attempt, claimed)
				}
			}
		})
	}
}

func TestPairingClaimAddsCurrentMagicDNSMetadataOnlyForTailscaleTicket(t *testing.T) {
	server := newPairingTestServer(t)
	server.router.tailscaleHostLookup = func(context.Context) tailscaleinfo.Host {
		return tailscaleinfo.Host{
			DNSName:    "studio-mac.tailnet.ts.net",
			DeviceName: "studio-mac",
		}
	}
	claim := func(endpoint string) pairingClaimResponse {
		t.Helper()
		now := time.Now().UTC()
		ticket := auth.NewPairingTicket(endpoint, testToken, now.Add(-time.Minute), now.Add(time.Minute))
		request := httptest.NewRequest(http.MethodPost, "/api/pair/claim", strings.NewReader(fmt.Sprintf(
			`{"endpoint":%q,"issued_at":%q,"expires_at":%q,"pair_sig":%q}`,
			ticket.Endpoint,
			ticket.IssuedAt,
			ticket.ExpiresAt,
			ticket.Signature,
		)))
		request.Header.Set("Content-Type", "application/json")
		response := httptest.NewRecorder()
		server.handler.ServeHTTP(response, request)
		if response.Code != http.StatusOK {
			t.Fatalf("配对失败：status=%d body=%s", response.Code, response.Body.String())
		}
		var decoded pairingClaimResponse
		if err := json.NewDecoder(response.Body).Decode(&decoded); err != nil {
			t.Fatal(err)
		}
		return decoded
	}

	tailscale := claim("http://100.64.0.10:8787")
	if tailscale.TailscaleDNSName != "studio-mac.tailnet.ts.net" ||
		tailscale.TailscaleDeviceName != "studio-mac" {
		t.Fatalf("Tailscale 配对应返回当前名称：%+v", tailscale)
	}
	lan := claim("http://192.168.1.10:8787")
	if lan.TailscaleDNSName != "" || lan.TailscaleDeviceName != "" {
		t.Fatalf("LAN 配对不应增加不可达的 Tailscale 路由：%+v", lan)
	}
}

func TestLocalPairingClaimOnlyReturnsTokenToNativeLoopbackRequest(t *testing.T) {
	server := newPairingTestServer(t)
	server.router.pairingStatus.probe = func(context.Context) runtimeStatusResponse {
		t.Error("automatic discovery requested an active assistant probe")
		return runtimeStatusResponse{}
	}

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

func TestPairingClaimAllowsConcurrentRetriesWhileTicketIsValid(t *testing.T) {
	server := newPairingTestServer(t)
	now := time.Now().UTC()
	ticket := auth.NewPairingTicket(
		"http://100.64.0.1:8787",
		testToken,
		now.Add(-time.Minute),
		now.Add(9*time.Minute),
	)
	payload := pairingClaimRequest{
		Endpoint:  ticket.Endpoint,
		IssuedAt:  ticket.IssuedAt,
		ExpiresAt: ticket.ExpiresAt,
		Signature: ticket.Signature,
	}
	const attempts = 24
	var wait sync.WaitGroup
	results := make(chan *httptest.ResponseRecorder, attempts)
	for range attempts {
		request := pairingClaimHTTPRequest(t, payload)
		wait.Add(1)
		go func() {
			defer wait.Done()
			response := httptest.NewRecorder()
			server.handler.ServeHTTP(response, request)
			results <- response
		}()
	}
	wait.Wait()
	close(results)

	for response := range results {
		if response.Code != http.StatusOK {
			t.Fatalf(
				"有效票据的并发重试都应成功，got=%d body=%s",
				response.Code,
				response.Body.String(),
			)
		}
	}
}

func TestPairingClaimRejectsExpiredTicketUnderConcurrentRetries(t *testing.T) {
	server := newPairingTestServer(t)
	now := time.Now().UTC()
	ticket := auth.NewPairingTicket(
		"http://100.64.0.1:8787",
		testToken,
		now.Add(-20*time.Minute),
		now.Add(-10*time.Minute),
	)
	payload := pairingClaimRequest{
		Endpoint:  ticket.Endpoint,
		IssuedAt:  ticket.IssuedAt,
		ExpiresAt: ticket.ExpiresAt,
		Signature: ticket.Signature,
	}
	const attempts = 24
	var wait sync.WaitGroup
	results := make(chan *httptest.ResponseRecorder, attempts)
	for range attempts {
		request := pairingClaimHTTPRequest(t, payload)
		wait.Add(1)
		go func() {
			defer wait.Done()
			response := httptest.NewRecorder()
			server.handler.ServeHTTP(response, request)
			results <- response
		}()
	}
	wait.Wait()
	close(results)

	for response := range results {
		if response.Code != http.StatusUnauthorized {
			t.Fatalf(
				"过期票据的并发重试必须稳定拒绝，got=%d body=%s",
				response.Code,
				response.Body.String(),
			)
		}
		if strings.Contains(response.Body.String(), testToken) {
			t.Fatal("过期响应不能泄漏长期 Token")
		}
	}
}

func performPairingClaimOverHTTP(
	t *testing.T,
	serverURL string,
	payload pairingClaimRequest,
) (int, []byte) {
	t.Helper()
	raw, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	request, err := http.NewRequest(
		http.MethodPost,
		serverURL+"/api/pair/claim",
		bytes.NewReader(raw),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	return response.StatusCode, body
}

func performPairingClaim(
	t *testing.T,
	handler http.Handler,
	payload pairingClaimRequest,
) *httptest.ResponseRecorder {
	t.Helper()
	request := pairingClaimHTTPRequest(t, payload)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	return response
}

func pairingClaimHTTPRequest(t *testing.T, payload pairingClaimRequest) *http.Request {
	t.Helper()
	request := authedRequest(t, http.MethodPost, "/api/pair/claim", payload)
	request.Header.Del("Authorization")
	return request
}

package httpapi

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/protocolcontract"
	"github.com/gaixianggeng/mimi-remote/internal/tailscaleinfo"
)

type clientCompatibilityFixture struct {
	Name                          string `json:"name"`
	ProtocolRevision              *int   `json:"protocol_revision"`
	MinimumServerProtocolRevision *int   `json:"minimum_server_protocol_revision"`
	ExpectedStatus                int    `json:"expected_status"`
	ExpectedCode                  string `json:"expected_code"`
}

type criticalJourneyFixture struct {
	SchemaVersion int `json:"schema_version"`
	REST          struct {
		PairClaim struct {
			Method       string `json:"method"`
			Path         string `json:"path"`
			RequiresAuth bool   `json:"requires_auth"`
		} `json:"pair_claim"`
	} `json:"rest"`
	WebSocket struct {
		Path                   string   `json:"path"`
		RequiresAuth           bool     `json:"requires_auth"`
		ClientMethods          []string `json:"client_methods"`
		ServerRequestMethods   []string `json:"server_request_methods"`
		ResolutionNotification string   `json:"resolution_notification"`
	} `json:"websocket"`
}

func TestVersionResponseMatchesSharedCurrentGoldenFixture(t *testing.T) {
	server := newTestServer(t)
	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodGet, "/api/version", nil)
	req.Header.Set(protocolcontract.ClientRevisionHeader, "2")
	req.Header.Set(protocolcontract.MinimumServerRevisionHeader, "1")

	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("当前客户端请求 /api/version 失败：status=%d body=%s", rec.Code, rec.Body.String())
	}
	var actual any
	if err := json.Unmarshal(rec.Body.Bytes(), &actual); err != nil {
		t.Fatalf("当前 /api/version 响应不是合法 JSON：%v", err)
	}
	var expected any
	if err := json.Unmarshal(readProtocolFixture(t, "version-current.json"), &expected); err != nil {
		t.Fatalf("当前 golden fixture 不是合法 JSON：%v", err)
	}
	// 共享 fixture 使用 darwin 供 iOS 解码测试；Go 端按实际构建目标验证动态平台值。
	expected.(map[string]any)["platform"] = runtime.GOOS
	actualJSON, _ := json.Marshal(actual)
	expectedJSON, _ := json.Marshal(expected)
	if string(actualJSON) != string(expectedJSON) {
		t.Fatalf("/api/version 与共享 golden fixture 漂移：\nactual=%s\nexpected=%s", actualJSON, expectedJSON)
	}
}

func TestVersionResponseOptionallyAdvertisesCurrentMagicDNSMetadata(t *testing.T) {
	server := newTestServer(t)
	server.router.tailscaleHostLookup = func(context.Context) tailscaleinfo.Host {
		return tailscaleinfo.Host{
			DNSName:    "studio-mac.tailnet.ts.net",
			DeviceName: "studio-mac",
		}
	}
	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/version", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("version 请求失败：status=%d body=%s", rec.Code, rec.Body.String())
	}
	var response protocolcontract.VersionResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatal(err)
	}
	if response.TailscaleDNSName != "studio-mac.tailnet.ts.net" ||
		response.TailscaleDeviceName != "studio-mac" {
		t.Fatalf("version 未宣告当前 Tailscale 名称：%+v", response)
	}
}

func TestVersionResponseOptionallyAdvertisesHostDeviceName(t *testing.T) {
	server := newTestServer(t)
	server.router.hostDeviceNameLookup = func(context.Context) string { return "工作室的 Mac Studio" }
	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/version", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("version 请求失败：status=%d body=%s", rec.Code, rec.Body.String())
	}
	var response protocolcontract.VersionResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatal(err)
	}
	if response.DeviceName != "工作室的 Mac Studio" {
		t.Fatalf("version 未宣告宿主设备名：%+v", response)
	}
}

// 读取不到设备名时字段必须省略，客户端据此继续按地址回退，而不是显示空名字。
func TestVersionResponseOmitsUnavailableHostDeviceName(t *testing.T) {
	server := newTestServer(t)
	server.router.hostDeviceNameLookup = func(context.Context) string { return "   " }
	rec := httptest.NewRecorder()
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/version", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("version 请求失败：status=%d body=%s", rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), "device_name") {
		t.Fatalf("空设备名不应出现在线协议里：%s", rec.Body.String())
	}
}

func TestCurrentAgentDRemainsDecodableByPreviousClient(t *testing.T) {
	server := newTestServer(t)
	rec := httptest.NewRecorder()

	// 上一版客户端没有协议 header；服务端必须按 revision 1 兼容窗口继续处理。
	server.handler.ServeHTTP(rec, authedRequest(t, http.MethodGet, "/api/version", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("上一版客户端应继续可用：status=%d body=%s", rec.Code, rec.Body.String())
	}

	var legacy struct {
		Name           string   `json:"name"`
		Version        string   `json:"version"`
		InstallationID string   `json:"installation_id"`
		Capabilities   []string `json:"capabilities"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &legacy); err != nil {
		t.Fatalf("上一版客户端模型应忽略新增字段并成功解码：%v", err)
	}
	if legacy.Name != "agentd" || legacy.Version != "test" || legacy.InstallationID != testInstallationID {
		t.Fatalf("上一版客户端需要的字段发生漂移：%+v", legacy)
	}
}

func TestClientCompatibilityMatrixAgainstCurrentAgentD(t *testing.T) {
	var fixtures []clientCompatibilityFixture
	if err := json.Unmarshal(readProtocolFixture(t, "client-matrix.json"), &fixtures); err != nil {
		t.Fatalf("客户端兼容矩阵不是合法 JSON：%v", err)
	}

	for _, fixture := range fixtures {
		t.Run(fixture.Name, func(t *testing.T) {
			server := newTestServer(t)
			rec := httptest.NewRecorder()
			req := authedRequest(t, http.MethodGet, "/api/version", nil)
			if fixture.ProtocolRevision != nil {
				req.Header.Set(protocolcontract.ClientRevisionHeader, revisionString(*fixture.ProtocolRevision))
			}
			if fixture.MinimumServerProtocolRevision != nil {
				req.Header.Set(protocolcontract.MinimumServerRevisionHeader, revisionString(*fixture.MinimumServerProtocolRevision))
			}

			server.handler.ServeHTTP(rec, req)

			if rec.Code != fixture.ExpectedStatus {
				t.Fatalf("兼容矩阵状态不符：got=%d want=%d body=%s", rec.Code, fixture.ExpectedStatus, rec.Body.String())
			}
			if fixture.ExpectedCode == "" {
				return
			}
			var body protocolErrorResponse
			if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
				t.Fatalf("协议错误不是结构化 JSON：%v", err)
			}
			if body.Code != fixture.ExpectedCode || body.Error == "" {
				t.Fatalf("协议错误不可诊断：%+v", body)
			}
			if body.ServerProtocolRevision != protocolcontract.CurrentRevision ||
				body.MinimumClientProtocolRevision != protocolcontract.MinimumSupportedClientRevision {
				t.Fatalf("协议错误缺少服务端兼容窗口：%+v", body)
			}
		})
	}
}

func TestWebSocketHandshakeRejectsIncompatibleClientBeforeUpgrade(t *testing.T) {
	server := newTestServer(t)
	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodGet, "/api/app-server/ws", nil)
	req.Header.Set("Connection", "upgrade")
	req.Header.Set("Upgrade", "websocket")
	req.Header.Set(protocolcontract.ClientRevisionHeader, "3")
	req.Header.Set(protocolcontract.MinimumServerRevisionHeader, "3")

	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusUpgradeRequired {
		t.Fatalf("不兼容 WS 握手必须在 upgrade 前失败：status=%d body=%s", rec.Code, rec.Body.String())
	}
	var body protocolErrorResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("WS 协议错误不是结构化 JSON：%v", err)
	}
	if body.Code != "protocol_incompatible" || body.Error == "" {
		t.Fatalf("WS 协议错误不可诊断：%+v", body)
	}
}

func TestProtocolMetadataDoesNotBypassAuthentication(t *testing.T) {
	server := newTestServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/version", nil)
	req.Header.Set(protocolcontract.ClientRevisionHeader, "3")
	req.Header.Set(protocolcontract.MinimumServerRevisionHeader, "3")

	server.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("未认证请求必须先被鉴权拒绝，实际 status=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestCriticalJourneyFixtureMatchesAgentDGateway(t *testing.T) {
	var fixture criticalJourneyFixture
	if err := json.Unmarshal(readProtocolFixture(t, "critical-journey.json"), &fixture); err != nil {
		t.Fatalf("关键链路 fixture 不是合法 JSON：%v", err)
	}
	if fixture.SchemaVersion != 1 {
		t.Fatalf("关键链路 fixture schema 不受支持：%d", fixture.SchemaVersion)
	}
	if fixture.REST.PairClaim.Method != http.MethodPost || fixture.REST.PairClaim.RequiresAuth {
		t.Fatalf("pair claim 必须保持免 Bearer 的 POST：%+v", fixture.REST.PairClaim)
	}

	// 用真实 mux 验证共享路径已注册；无效 body 可以被 handler 拒绝，但不能落到 404。
	server := newTestServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(
		fixture.REST.PairClaim.Method,
		fixture.REST.PairClaim.Path,
		http.NoBody,
	)
	server.handler.ServeHTTP(rec, req)
	if rec.Code == http.StatusNotFound || rec.Code == http.StatusUnauthorized {
		t.Fatalf("pair claim 共享路径或免认证边界漂移：status=%d", rec.Code)
	}

	if fixture.WebSocket.Path != appServerGatewayPath || !fixture.WebSocket.RequiresAuth {
		t.Fatalf("app-server WebSocket 路径或鉴权边界漂移：%+v", fixture.WebSocket)
	}
	for _, method := range fixture.WebSocket.ClientMethods {
		if _, ok := appServerAllowedMethods[method]; !ok {
			t.Errorf("共享关键链路方法未被 agentd gateway 允许：%s", method)
		}
	}
	for _, method := range fixture.WebSocket.ServerRequestMethods {
		if _, ok := appServerAllowedServerRequestMethods[method]; !ok {
			t.Errorf("共享反向请求未被 agentd gateway 允许：%s", method)
		}
	}
	if fixture.WebSocket.ResolutionNotification != "serverRequest/resolved" {
		t.Fatalf(
			"审批/补充输入的收敛通知漂移：%s",
			fixture.WebSocket.ResolutionNotification,
		)
	}
}

func readProtocolFixture(t *testing.T, name string) []byte {
	t.Helper()
	path := filepath.Join("..", "..", "contracts", "mimi-protocol", "fixtures", name)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读取共享协议 fixture %s 失败：%v", name, err)
	}
	return data
}

func revisionString(value int) string {
	return fmt.Sprintf("%d", value)
}

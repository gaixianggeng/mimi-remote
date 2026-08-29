package httpapi

import (
	"bytes"
	"encoding/json"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/doctor"
	"github.com/gaixianggeng/mimi-remote/internal/protocolcontract"
)

func TestFileUploadCapabilityRolloutMatrix(t *testing.T) {
	tests := []struct {
		name              string
		configure         func(*testing.T, *config.Config)
		wantState         string
		wantReason        string
		wantDeclared      bool
		wantEndpointCode  int
		wantErrorCode     string
		wantDoctorWarning bool
	}{
		{
			name:             "enabled",
			wantState:        capabilityStateEnabled,
			wantReason:       capabilityReasonAvailable,
			wantDeclared:     true,
			wantEndpointCode: http.StatusCreated,
		},
		{
			name: "locally-disabled",
			configure: func(_ *testing.T, cfg *config.Config) {
				cfg.Capabilities.Disabled = []string{fileUploadCapability}
			},
			wantState:         capabilityStateLocallyDisabled,
			wantReason:        capabilityReasonDisabledByLocalConfig,
			wantEndpointCode:  http.StatusServiceUnavailable,
			wantErrorCode:     "capability_locally_disabled",
			wantDoctorWarning: true,
		},
		{
			name: "dependency-unavailable",
			configure: func(t *testing.T, _ *config.Config) {
				blockingFile := filepath.Join(t.TempDir(), "not-a-directory")
				if err := os.WriteFile(blockingFile, []byte("blocked"), 0o600); err != nil {
					t.Fatal(err)
				}
				t.Setenv("AGENTD_FILE_UPLOAD_CACHE_DIR", blockingFile)
			},
			wantState:         capabilityStateDependencyUnavailable,
			wantReason:        capabilityReasonStorageUnavailable,
			wantEndpointCode:  http.StatusServiceUnavailable,
			wantErrorCode:     "capability_dependency_unavailable",
			wantDoctorWarning: true,
		},
		{
			name: "unknown-disable-is-harmless",
			configure: func(_ *testing.T, cfg *config.Config) {
				cfg.Capabilities.Disabled = []string{"future_safe_path_v2"}
			},
			wantState:        capabilityStateEnabled,
			wantReason:       capabilityReasonAvailable,
			wantDeclared:     true,
			wantEndpointCode: http.StatusCreated,
		},
	}

	for _, item := range tests {
		t.Run(item.name, func(t *testing.T) {
			t.Setenv("AGENTD_FILE_UPLOAD_CACHE_DIR", filepath.Join(t.TempDir(), "uploads"))
			server := newTestServerWithConfig(t, func(cfg *config.Config) {
				if item.configure != nil {
					item.configure(t, cfg)
				}
			})

			versionRecorder := httptest.NewRecorder()
			server.handler.ServeHTTP(
				versionRecorder,
				authedRequest(t, http.MethodGet, "/api/version", nil),
			)
			var version protocolcontract.VersionResponse
			if err := json.NewDecoder(versionRecorder.Body).Decode(&version); err != nil {
				t.Fatalf("版本响应无法解码：%v", err)
			}
			if capabilityListContains(version.Capabilities, fileUploadCapability) != item.wantDeclared {
				t.Fatalf("capability 声明不符：%+v", version.Capabilities)
			}
			if len(version.CapabilityStatuses) != 2 {
				t.Fatalf("状态声明应覆盖已知可选能力：%+v", version.CapabilityStatuses)
			}
			status := findCapabilityStatus(version.CapabilityStatuses, fileUploadCapability)
			if status.Name != fileUploadCapability ||
				status.State != item.wantState ||
				status.Reason != item.wantReason {
				t.Fatalf("能力状态不符：%+v", status)
			}
			remoteFullAccess := findCapabilityStatus(
				version.CapabilityStatuses,
				codexRemoteFullAccessCapability,
			)
			if !capabilityListContains(version.Capabilities, codexRemoteFullAccessCapability) ||
				remoteFullAccess.State != capabilityStateEnabled ||
				remoteFullAccess.Reason != capabilityReasonAvailable {
				t.Fatalf("远程完全访问能力未声明：%+v", remoteFullAccess)
			}

			uploadRecorder := httptest.NewRecorder()
			server.handler.ServeHTTP(
				uploadRecorder,
				rawFileUploadRequest(t, "matrix.txt", "matrix-upload-key", []byte("matrix")),
			)
			if uploadRecorder.Code != item.wantEndpointCode {
				t.Fatalf("端点状态不符：got=%d want=%d body=%s", uploadRecorder.Code, item.wantEndpointCode, uploadRecorder.Body.String())
			}
			if item.wantErrorCode != "" {
				var response struct {
					Code       string `json:"code"`
					Capability string `json:"capability"`
					State      string `json:"state"`
				}
				if err := json.NewDecoder(uploadRecorder.Body).Decode(&response); err != nil {
					t.Fatal(err)
				}
				if response.Code != item.wantErrorCode ||
					response.Capability != fileUploadCapability ||
					response.State != item.wantState {
					t.Fatalf("fail-closed 响应不可诊断：%+v", response)
				}
			}

			doctorRecorder := httptest.NewRecorder()
			server.handler.ServeHTTP(
				doctorRecorder,
				authedRequest(t, http.MethodGet, "/api/doctor", nil),
			)
			var results doctor.Results
			if err := json.NewDecoder(doctorRecorder.Body).Decode(&results); err != nil {
				t.Fatal(err)
			}
			check := findDoctorCheck(results.Checks, "capability-file-upload-v1")
			if check.Name == "" || check.OK != !item.wantDoctorWarning ||
				check.Capability != fileUploadCapability ||
				check.State != item.wantState ||
				check.Reason != item.wantReason ||
				(item.wantDoctorWarning && check.Level != "warning") {
				t.Fatalf("Doctor 能力状态不符：%+v", check)
			}

			// agentd status --json 读取 readyz 中的 doctor checks；可选能力 warning
			// 不改变基础链路就绪语义，但必须保留同一组稳定状态码。
			readinessRecorder := httptest.NewRecorder()
			server.handler.ServeHTTP(
				readinessRecorder,
				authedRequest(t, http.MethodGet, "/api/readyz", nil),
			)
			var readiness doctor.Results
			if err := json.NewDecoder(readinessRecorder.Body).Decode(&readiness); err != nil {
				t.Fatal(err)
			}
			readinessCheck := findDoctorCheck(
				readiness.Checks,
				"capability-file-upload-v1",
			)
			if readinessCheck.State != item.wantState ||
				readinessCheck.Reason != item.wantReason {
				t.Fatalf("status/readyz 能力状态不符：%+v", readinessCheck)
			}
		})
	}
}

func TestCodexRemoteFullAccessCapabilityCanBeDisabledLocally(t *testing.T) {
	t.Setenv("AGENTD_FILE_UPLOAD_CACHE_DIR", t.TempDir())
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Capabilities.Disabled = []string{codexRemoteFullAccessCapability}
	})
	recorder := httptest.NewRecorder()
	server.handler.ServeHTTP(
		recorder,
		authedRequest(t, http.MethodGet, "/api/version", nil),
	)
	var version protocolcontract.VersionResponse
	if err := json.NewDecoder(recorder.Body).Decode(&version); err != nil {
		t.Fatal(err)
	}
	status := findCapabilityStatus(version.CapabilityStatuses, codexRemoteFullAccessCapability)
	if capabilityListContains(version.Capabilities, codexRemoteFullAccessCapability) ||
		status.State != capabilityStateLocallyDisabled ||
		status.Reason != capabilityReasonDisabledByLocalConfig {
		t.Fatalf("本地禁用后仍不应向 iOS 授权免审批路径：%+v", version)
	}
}

func TestCapabilityDecisionLogContainsStateButNoCredentials(t *testing.T) {
	t.Setenv("AGENTD_FILE_UPLOAD_CACHE_DIR", t.TempDir())
	var output bytes.Buffer
	previous := log.Writer()
	log.SetOutput(&output)
	t.Cleanup(func() { log.SetOutput(previous) })

	_ = newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Capabilities.Disabled = []string{fileUploadCapability}
	})

	text := output.String()
	if !strings.Contains(text, "state=locally_disabled") ||
		!strings.Contains(text, "reason=disabled_by_local_config") {
		t.Fatalf("启动日志应包含稳定能力决策：%s", text)
	}
	if strings.Contains(text, testToken) {
		t.Fatalf("能力日志不能包含访问凭据：%s", text)
	}
}

func capabilityListContains(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func findCapabilityStatus(
	statuses []protocolcontract.CapabilityStatus,
	target string,
) protocolcontract.CapabilityStatus {
	for _, status := range statuses {
		if status.Name == target {
			return status
		}
	}
	return protocolcontract.CapabilityStatus{}
}

func findDoctorCheck(checks []doctor.Check, name string) doctor.Check {
	for _, check := range checks {
		if check.Name == name {
			return check
		}
	}
	return doctor.Check{}
}

package httpapi

import (
	"net/http"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/auth"
)

type DiagnosticLogStatus struct {
	Enabled        bool       `json:"enabled"`
	ExpiresAt      *time.Time `json:"expires_at,omitempty"`
	CurrentBytes   int64      `json:"current_bytes"`
	PreviousBytes  int64      `json:"previous_bytes"`
	TotalBytes     int64      `json:"total_bytes"`
	MaxTotalBytes  int64      `json:"max_total_bytes"`
	RetentionDays  int        `json:"retention_days"`
	DroppedRecords int64      `json:"dropped_records,omitempty"`
}

type DiagnosticLogController interface {
	Status() (DiagnosticLogStatus, error)
	SetEnabled(bool) (DiagnosticLogStatus, error)
	Clear() (DiagnosticLogStatus, error)
	Export() ([]string, error)
}

func (r *Router) registerLocalDiagnostics(mux *http.ServeMux, token string) {
	// 使用独立的本机凭据：Tailcat 等 TCP 隧道会让远端连接也呈现回环来源。
	// 即使业务接口允许开发模式，也不能让浏览器或配对客户端控制主机日志。
	strict := auth.NewWithOptions(token, false, auth.Options{})
	mux.Handle("/api/local/diagnostics/", strict.Middleware(http.HandlerFunc(r.localDiagnostics)))
}

func (r *Router) localDiagnostics(w http.ResponseWriter, req *http.Request) {
	if !isLoopbackPairingRequest(req) {
		writeError(w, http.StatusForbidden, "诊断日志控制仅允许本机连接")
		return
	}
	if req.Header.Get("Origin") != "" {
		writeError(w, http.StatusForbidden, "诊断日志控制不接受网页请求")
		return
	}
	action := req.URL.Path[len("/api/local/diagnostics/"):]
	method := http.MethodPost
	switch action {
	case "status", "export":
		method = http.MethodGet
	case "start", "stop", "clear":
	default:
		http.NotFound(w, req)
		return
	}
	if req.Method != method {
		methodNotAllowed(w)
		return
	}
	if r.diagnosticLogs == nil {
		writeError(w, http.StatusServiceUnavailable, "当前服务未启用托管诊断文件")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	var value any
	var err error
	switch action {
	case "status":
		value, err = r.diagnosticLogs.Status()
	case "start":
		value, err = r.diagnosticLogs.SetEnabled(true)
	case "stop":
		value, err = r.diagnosticLogs.SetEnabled(false)
	case "clear":
		value, err = r.diagnosticLogs.Clear()
	case "export":
		var lines []string
		lines, err = r.diagnosticLogs.Export()
		value = struct {
			Lines []string `json:"lines"`
		}{Lines: lines}
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "诊断日志操作失败，请检查磁盘空间和文件权限")
		return
	}
	writeJSON(w, http.StatusOK, value)
}

package httpapi

import (
	"context"
	"errors"
	"log"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/auth"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
)

type tailcatManagedPairingLinkRequest struct {
	ConfirmResetSelfHosted bool `json:"confirm_reset_self_hosted"`
}

type tailcatManagedPairingLinkResponse struct {
	PairURL       string `json:"pair_url"`
	PairExpiresAt string `json:"pair_expires_at"`
	Mode          string `json:"mode"`
}

type tailcatActionFailure struct {
	status            int
	code              string
	err               error
	pairedDeviceCount *int
}

func (r *Router) tailcatManagedPairingLinkHandler(w http.ResponseWriter, req *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	result := "ok"
	// 只记录固定结果码，不能记录底层错误、链接、来源地址、公钥或凭证。
	defer func() { log.Printf("tailcat managed pairing link: result=%s", result) }()
	if req.Method != http.MethodPost {
		result = "method_not_allowed"
		methodNotAllowed(w)
		return
	}
	var payload tailcatManagedPairingLinkRequest
	if !decodeJSONRequest(w, req, &payload) {
		result = "invalid_request"
		return
	}
	// 不排队执行重复升级，避免慢配对期间积压请求并连续销毁临时节点。
	if !r.tailcatControlMu.TryLock() {
		result = "tailcat_operation_in_progress"
		writeJSON(w, http.StatusConflict, map[string]string{"code": result, "error": "Tailcat 正在执行其他操作，请稍后重试"})
		return
	}
	defer r.tailcatControlMu.Unlock()
	response, failure := r.createTailcatManagedPairingLink(req.Context(), payload)
	if failure != nil {
		result = failure.code
		body := map[string]any{"code": failure.code, "error": failure.err.Error()}
		if failure.pairedDeviceCount != nil {
			body["paired_device_count"] = *failure.pairedDeviceCount
		}
		writeJSON(w, failure.status, body)
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func (r *Router) createTailcatManagedPairingLink(
	ctx context.Context,
	payload tailcatManagedPairingLinkRequest,
) (tailcatManagedPairingLinkResponse, *tailcatActionFailure) {
	fail := func(status int, code, message string) (tailcatManagedPairingLinkResponse, *tailcatActionFailure) {
		return tailcatManagedPairingLinkResponse{}, &tailcatActionFailure{status: status, code: code, err: errors.New(message)}
	}
	if r.tailcat == nil || r.managedPairing == nil || strings.TrimSpace(r.installationID) == "" {
		return fail(http.StatusServiceUnavailable, "tailcat_managed_pairing_unavailable", "Mimi 托管连接尚未初始化")
	}
	// 先检查配对前提，避免明知不能配对仍清除用户的自建身份。
	if !r.cfg.HasEnabledAgent() {
		return fail(http.StatusServiceUnavailable, "tailcat_agents_disabled", "全部 AI 编程助手已关闭，请先启用助手")
	}
	status := r.tailcat.Status(ctx)
	if !status.Enabled || !status.Running {
		if failure := r.enableTailcat(ctx); failure != nil {
			// 本机接口保留详细错误；远程接口只返回固定提示，避免泄露本机路径等信息。
			message := "开启 Tailcat 失败，请在电脑上检查配置和辅助程序"
			if failure.code == "tailcat_enable_rollback_failed" {
				message = "开启 Tailcat 失败，恢复关闭状态也失败，请在电脑上检查"
			}
			return fail(failure.status, failure.code, message)
		}
		status = r.tailcat.Status(ctx)
	}
	// Status 失败时设备数的零值不可信，不能据此免确认并删除已有配对。
	if !status.Running || status.Error != "" || status.PairedDeviceCount < 0 {
		return fail(http.StatusServiceUnavailable, "tailcat_status_unavailable", "无法读取 Tailcat 设备状态，请稍后重试")
	}
	// sidecar 的 tunnel.StartHost 使用普通 TCP 转发到 loopback，没有可信来源标记。
	// RemoteAddr/Host/Forwarded 均无法区分 Tailcat 和本机调用，因此所有自建设备都需确认。
	if status.Mode != config.TailcatModeManaged && status.PairedDeviceCount > 0 && !payload.ConfirmResetSelfHosted {
		_, failure := fail(http.StatusConflict, "tailcat_self_hosted_clients_present", "已有自建 Tailcat 设备，进入托管模式会断开这些设备，请确认后重试")
		failure.pairedDeviceCount = &status.PairedDeviceCount
		return tailcatManagedPairingLinkResponse{}, failure
	}
	if _, err := r.managedPairing.ConfigureMode(ctx, true); err != nil {
		return fail(http.StatusServiceUnavailable, "tailcat_managed_mode_failed", "进入托管模式失败，已尝试恢复原状态，请在电脑上检查")
	}
	status, failure := r.pairTailcat(ctx)
	if failure != nil {
		return fail(failure.status, failure.code, "生成 Tailcat 配对节点失败，请稍后重试")
	}
	if status.Mode != config.TailcatModeManaged || !status.Running || status.Error != "" ||
		strings.TrimSpace(status.PairAddress) == "" || !validManagedTailcatPublicKey(status.PublicKey) ||
		!validManagedTailcatPublicKey(status.PairPublicKey) {
		return fail(http.StatusServiceUnavailable, "tailcat_pair_failed", "Tailcat 托管配对节点尚未就绪，请稍后重试")
	}
	nodeExpiry, err := time.Parse(time.RFC3339Nano, status.PairExpiresAt)
	if err != nil || !nodeExpiry.After(time.Now()) {
		return fail(http.StatusServiceUnavailable, "tailcat_pair_failed", "Tailcat 配对节点已失效，请重新生成")
	}
	// 与 agentd tailcat pair 共用二维码构造函数，字段及签名语义保持一致。
	pair, err := agentsetup.TailcatPairWithManagedHost(
		r.configPath, status.PairAddress, status.MacInstallationID, status.PublicKey, status.PairPublicKey,
	)
	if err != nil {
		return fail(http.StatusInternalServerError, "tailcat_pair_link_failed", "生成 Tailcat 配对链接失败，请在电脑上检查配置")
	}
	// 构造器从磁盘读配置，claim 使用进程中的 Token。配置被删除或凭证被修改时，
	// 不能把当前进程无法验证的链接交给客户端。
	link, err := url.Parse(pair.PairURL)
	if err != nil || auth.ValidatePairingTicket(r.cfg.Auth.Token, auth.PairingTicket{
		Endpoint: pair.Endpoint, IssuedAt: pair.PairIssuedAt, ExpiresAt: pair.PairExpiresAt,
		Signature: link.Query().Get("pair_sig"),
	}, time.Now()) != nil {
		return fail(http.StatusInternalServerError, "tailcat_pair_link_failed", "配对签名与当前服务不一致，请在电脑上检查配置并重启服务")
	}
	// Pair 可能复用超时后才生成的旧节点，返回较早的有效期，避免客户端多显示数分钟。
	if ticketExpiry, _ := time.Parse(time.RFC3339Nano, pair.PairExpiresAt); nodeExpiry.Before(ticketExpiry) {
		pair.PairExpiresAt = nodeExpiry.UTC().Format(time.RFC3339Nano)
	}
	return tailcatManagedPairingLinkResponse{
		PairURL: pair.PairURL, PairExpiresAt: pair.PairExpiresAt, Mode: status.Mode,
	}, nil
}

// enableTailcat 和 pairTailcat 同时服务本机动作与远程升级；调用者持有 tailcatControlMu。
func (r *Router) enableTailcat(ctx context.Context) *tailcatActionFailure {
	if _, err := agentsetup.ConfigureTailcat(r.configPath, true); err != nil {
		return &tailcatActionFailure{status: http.StatusInternalServerError, code: "tailcat_enable_failed", err: err}
	}
	if err := r.tailcat.Start(ctx); err != nil {
		// 请求取消也要恢复关闭状态，沿用 enable 失败后禁用配置并停止进程的语义。
		cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
		defer cancel()
		_, configErr := agentsetup.ConfigureTailcat(r.configPath, false)
		stopErr := r.tailcat.Stop(cleanup)
		code := "tailcat_enable_failed"
		if configErr != nil || stopErr != nil {
			code = "tailcat_enable_rollback_failed"
		}
		return &tailcatActionFailure{status: http.StatusServiceUnavailable, code: code, err: errors.Join(err, configErr, stopErr)}
	}
	if r.managedPairing != nil {
		r.managedPairing.Start()
		// 与原本机 enable 一致：离线策略同步失败不撤销已成功启动的 sidecar。
		_ = r.managedPairing.Sync(ctx)
	}
	return nil
}

func (r *Router) pairTailcat(ctx context.Context) (tailcatStatus, *tailcatActionFailure) {
	if !r.cfg.HasEnabledAgent() {
		return tailcatStatus{}, &tailcatActionFailure{
			status: http.StatusServiceUnavailable, code: "tailcat_agents_disabled",
			err: errors.New("全部 AI 编程助手已关闭，请先启用助手"),
		}
	}
	status, err := r.tailcat.Pair(ctx)
	if err != nil {
		return tailcatStatus{}, &tailcatActionFailure{status: http.StatusServiceUnavailable, code: "tailcat_pair_failed", err: err}
	}
	return r.decorateTailcatStatus(status), nil
}

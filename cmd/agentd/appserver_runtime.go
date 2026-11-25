package main

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/httpapi"
)

type agentAppServerRuntime struct {
	transport httpapi.AppServerTransport
	managedWS *appserver.ManagedWebSocketProcess
}

func prepareAgentAppServerRuntime(cfg config.Config) (*agentAppServerRuntime, error) {
	return prepareAgentAppServerRuntimeWithFrontDoor(context.Background(), cfg, false)
}

func prepareAgentAppServerRuntimeWithFrontDoor(ctx context.Context, cfg config.Config, frontDoorRequired bool) (*agentAppServerRuntime, error) {
	result := &agentAppServerRuntime{}
	if !cfg.Codex.IsEnabled() {
		return result, nil
	}
	if err := cfg.ValidateSharedCodexHome(); err != nil {
		return nil, err
	}
	if cfg.AppServer.SharedCodexHome != "" && !frontDoorRequired {
		return nil, fmt.Errorf("app_server.shared_codex_home 需要 Mac App 的受管前门，不能回退为独立 resident")
	}
	prepareCtx, cancel := context.WithTimeout(ctx, 25*time.Second)
	defer cancel()
	switch strings.ToLower(strings.TrimSpace(cfg.AppServer.Transport)) {
	case "ssh":
		transport, err := appserver.NewSSHTransport(appserver.SSHTransportOptions{Target: cfg.AppServer.SSHTarget})
		if err != nil {
			return nil, fmt.Errorf("初始化 SSH App Server transport 失败：%w", err)
		}
		if _, err := transport.CheckRemoteCodex(prepareCtx); err != nil {
			transport.Shutdown()
			return nil, err
		}
		result.transport = transport
	case "local":
		transport, err := appserver.NewSharedLocalTransport(appserver.SharedLocalOptions{
			CodexBin:         cfg.Codex.Bin,
			Env:              cfg.Codex.Env,
			ConnectOnly:      frontDoorRequired,
			BackendCodexHome: cfg.AppServer.SharedCodexHome,
		})
		if err != nil {
			return nil, fmt.Errorf("初始化共享本机 App Server transport 失败：%w", err)
		}
		result.transport = transport
	case "ws":
		if !config.SupportsManagedAppServer() {
			return nil, fmt.Errorf("受管 app-server WebSocket 只支持 Windows 本机宿主")
		}
		process, err := appserver.StartManagedWebSocket(prepareCtx, appserver.ManagedWebSocketOptions{
			CodexBin:    cfg.Codex.Bin,
			Env:         cfg.Codex.Env,
			Listen:      cfg.AppServer.Listen,
			WSTokenFile: cfg.AppServer.WSTokenFile,
		})
		if err != nil {
			return nil, err
		}
		if err := process.WaitReady(prepareCtx); err != nil {
			_ = process.Shutdown(context.Background())
			return nil, fmt.Errorf("本机 Codex app-server initialize 失败：%w", err)
		}
		result.transport = process
		result.managedWS = process
	default:
		return nil, fmt.Errorf("当前 iPad 链路只支持 app_server.transport=ssh；macOS 与 Linux 另支持共享 local，Windows 另支持受管 ws")
	}
	return result, nil
}

func (r *agentAppServerRuntime) shutdown() error {
	if r == nil || r.managedWS == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	return r.managedWS.Shutdown(ctx)
}

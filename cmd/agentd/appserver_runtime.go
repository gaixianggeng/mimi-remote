package main

import (
	"context"
	"fmt"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/httpapi"
)

type agentAppServerRuntime struct {
	routerOptions httpapi.RouterOptions
	supervisor    *codexSupervisor
}

func prepareAgentAppServerRuntime(cfg config.Config) (*agentAppServerRuntime, error) {
	return prepareAgentAppServerRuntimeWithFrontDoor(cfg, false)
}

func prepareAgentAppServerRuntimeWithFrontDoor(cfg config.Config, frontDoorRequired bool) (*agentAppServerRuntime, error) {
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
	var connect func(context.Context) (httpapi.AppServerTransport, error)
	var stopShared func()
	switch strings.ToLower(strings.TrimSpace(cfg.AppServer.Transport)) {
	case "ssh":
		transport, err := appserver.NewSSHTransport(appserver.SSHTransportOptions{Target: cfg.AppServer.SSHTarget})
		if err != nil {
			return nil, fmt.Errorf("初始化 SSH App Server transport 失败：%w", err)
		}
		connect = func(ctx context.Context) (httpapi.AppServerTransport, error) {
			if _, err := transport.CheckRemoteCodex(ctx); err != nil {
				return nil, err
			}
			return transport, transport.EnsureReady(ctx)
		}
		stopShared = transport.Shutdown
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
		connect = func(ctx context.Context) (httpapi.AppServerTransport, error) {
			if _, err := appserver.CheckLocalCodex(ctx, cfg.Codex.Bin); err != nil {
				return nil, err
			}
			return transport, transport.EnsureReady(ctx)
		}
	case "ws":
		if !config.SupportsManagedAppServer() {
			return nil, fmt.Errorf("受管 app-server WebSocket 只支持 Windows 本机宿主")
		}
		options := appserver.ManagedWebSocketOptions{
			CodexBin: cfg.Codex.Bin, Env: cfg.Codex.Env, Listen: cfg.AppServer.Listen, WSTokenFile: cfg.AppServer.WSTokenFile,
		}
		connect = func(ctx context.Context) (httpapi.AppServerTransport, error) {
			return startReadyManagedCodex(ctx, options)
		}
	default:
		return nil, fmt.Errorf("当前 iPad 链路只支持 app_server.transport=ssh；macOS 与 Linux 另支持共享 local，Windows 另支持受管 ws")
	}
	result.supervisor = startCodexSupervisor(connect, stopShared, codexRetryMin)
	result.routerOptions.AppServerSSH = result.supervisor
	return result, nil
}

func startReadyManagedCodex(ctx context.Context, options appserver.ManagedWebSocketOptions) (httpapi.AppServerTransport, error) {
	process, err := appserver.StartManagedWebSocket(ctx, options)
	if err != nil {
		return nil, err
	}
	if err := process.WaitReady(ctx); err != nil {
		_ = process.Shutdown(context.Background())
		return nil, fmt.Errorf("本机 Codex app-server initialize 失败：%w", err)
	}
	return process, nil
}

func (r *agentAppServerRuntime) shutdown() error {
	if r == nil || r.supervisor == nil {
		return nil
	}
	return r.supervisor.shutdown()
}

func shutdownServeResources(apiRouter *httpapi.Router, appServerRuntime *agentAppServerRuntime) error {
	if apiRouter != nil {
		apiRouter.Shutdown()
	}
	return appServerRuntime.shutdown()
}

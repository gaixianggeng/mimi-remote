package main

import (
	"context"
	"fmt"
	"log"
	"runtime"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/httpapi"
	"github.com/gaixianggeng/mimi-remote/internal/session"
)

type agentAppServerRuntime struct {
	routerOptions httpapi.RouterOptions
	managedWS     *appserver.ManagedWebSocketProcess
}

func prepareAgentAppServerRuntime(cfg config.Config) (*agentAppServerRuntime, error) {
	result := &agentAppServerRuntime{}
	prepareCtx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	switch strings.ToLower(strings.TrimSpace(cfg.AppServer.Transport)) {
	case "ssh":
		transport, err := appserver.NewSSHTransport(appserver.SSHTransportOptions{Target: cfg.AppServer.SSHTarget})
		if err != nil {
			return nil, fmt.Errorf("初始化 SSH App Server transport 失败：%w", err)
		}
		remoteVersion, err := transport.CheckRemoteCodex(prepareCtx)
		if err != nil {
			return nil, err
		}
		if err := transport.EnsureReady(prepareCtx); err != nil {
			return nil, err
		}
		log.Printf("agentd shared app-server ssh target=%s codex_version=%s", transport.Target(), remoteVersion)
		result.routerOptions.AppServerSSH = transport
	case "local":
		transport, err := appserver.NewSharedLocalTransport(appserver.SharedLocalOptions{
			CodexBin: cfg.Codex.Bin,
			Env:      cfg.Codex.Env,
		})
		if err != nil {
			return nil, fmt.Errorf("初始化共享本机 App Server transport 失败：%w", err)
		}
		localVersion, err := appserver.CheckLocalCodex(prepareCtx, cfg.Codex.Bin)
		if err != nil {
			return nil, err
		}
		if err := transport.EnsureReady(prepareCtx); err != nil {
			return nil, err
		}
		log.Printf("agentd shared local app-server socket=%s codex_version=%s", transport.SocketPath(), localVersion)
		result.routerOptions.AppServerSSH = transport
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
		log.Printf("agentd managed local app-server ws upstream=%s platform=%s", cfg.AppServer.Listen, runtime.GOOS)
		result.routerOptions.AppServerSSH = process
		result.managedWS = process
	default:
		return nil, fmt.Errorf("当前 iPad 链路只支持 app_server.transport=ssh；Linux 另支持共享 local，Windows 另支持受管 ws")
	}
	return result, nil
}

func (r *agentAppServerRuntime) watch(errCh chan<- error) {
	if r == nil || r.managedWS == nil {
		return
	}
	go func() {
		<-r.managedWS.Done()
		err := r.managedWS.ExitError()
		if err == nil {
			err = fmt.Errorf("受管 Codex app-server 已退出")
		} else {
			err = fmt.Errorf("受管 Codex app-server 异常退出：%w", err)
		}
		errCh <- err
	}()
}

func (r *agentAppServerRuntime) shutdown() error {
	if r == nil || r.managedWS == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	return r.managedWS.Shutdown(ctx)
}

func shutdownServeResources(
	manager *session.Manager,
	apiRouter *httpapi.Router,
	appServerRuntime *agentAppServerRuntime,
) error {
	if manager != nil {
		manager.Shutdown()
	}
	if apiRouter != nil {
		apiRouter.Shutdown()
	}
	// SSH and Linux local residents are shared and preserved. The managed
	// WebSocket process is owned by agentd and stopped on Windows.
	return appServerRuntime.shutdown()
}

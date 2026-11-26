package main

import (
	"context"
	"net"
	"net/http"
	"net/netip"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/setup"
)

// Ignore AGENTD_CONFIG when identifying the file used by the system manager.
// Resolve directory aliases and apply the volume's case sensitivity, exactly
// as for config publication. An identity lookup failure stays fail-closed.
func isManagedCoreConfig(path string) bool {
	if path == "" {
		return false
	}
	wanted, e1 := config.ConfigPathIdentity(config.PlatformDefaultPath())
	actual, e2 := config.ConfigPathIdentity(path)
	return e1 != nil || e2 != nil || actual == wanted
}

type coreDialFunc func(context.Context, string, string) (net.Conn, error)

func coreDialForConfig(path string) coreDialFunc {
	return coreDialForOwner(isManagedCoreConfig(path))
}

func coreDialForOwner(managed bool) coreDialFunc {
	return func(parent context.Context, _ string, address string) (net.Conn, error) {
		target, err := netip.ParseAddrPort(address)
		if err != nil || !target.Addr().IsLoopback() {
			return nil, errUnknownCoreOwner
		}
		ctx, cancel := context.WithTimeout(parent, 6*time.Second)
		defer cancel()
		conn, err := (&net.Dialer{}).DialContext(ctx, "tcp", address)
		if err != nil {
			return nil, err
		}
		var trusted bool
		if managed {
			owner, e := inspectCorePeer(ctx, managedServicePlatform, conn)
			trusted = e == nil && owner.manager != ""
		} else {
			trusted = trustedForegroundPeer(ctx, conn)
		}
		if !trusted {
			conn.Close()
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			return nil, setup.PreflightHostError("service_port_in_use")
		}
		return conn, nil
	}
}

func coreHTTPClient(ctx context.Context, path string) *http.Client {
	return coreHTTPClientWithDial(ctx, coreDialForConfig(path))
}

func coreHTTPClientWithDial(ctx context.Context, dial coreDialFunc) *http.Client {
	return &http.Client{
		Transport: &http.Transport{DisableKeepAlives: true, MaxResponseHeaderBytes: 16 << 10, DialContext: func(_ context.Context, network, address string) (net.Conn, error) {
			// net/http can detach a pooled dial from request cancellation. Each
			// control probe owns one connection, under its original request deadline.
			return dial(ctx, network, address)
		}},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
}

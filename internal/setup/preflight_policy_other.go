//go:build !windows

package setup

import (
	"context"
	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func preflightLANPolicy(context.Context, bool) string { return "" }

func confirmPlatformPairingLAN(context.Context, config.Config) error { return nil }

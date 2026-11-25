//go:build !windows

package setup

import "context"

func preflightLANPolicy(context.Context, bool) string { return "" }

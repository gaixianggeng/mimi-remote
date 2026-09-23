//go:build !darwin

package appserver

import "context"

func validateSharedLocalLaunchSession(context.Context) error { return nil }

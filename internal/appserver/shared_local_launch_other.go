//go:build !darwin

package appserver

import "context"

func validateSharedLocalLaunchSession(context.Context) error { return nil }

func sharedLocalAppServerArgs(_ context.Context, _ string, _ map[string]string, listen string) ([]string, error) {
	return []string{"-c", "features.code_mode_host=true", "app-server", "--listen", listen}, nil
}

//go:build !darwin

package setup

import "context"

func desktopSyncLegacyArtifactsPresent() (bool, error) { return false, nil }

func cleanupDesktopSyncLegacyArtifacts(context.Context) error { return nil }

package setup

import (
	"context"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func withConfigCommitLock(ctx context.Context, path string, commit func() error) error {
	return config.WithConfigCommitLock(ctx, path, func() error {
		if err := config.CheckSetupWriteAvailable(path); err != nil {
			return recoveryError(config.SetupJournalPath(path), err)
		}
		return commit()
	})
}

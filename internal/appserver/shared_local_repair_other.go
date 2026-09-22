//go:build !darwin

package appserver

import (
	"context"
	"errors"
)

func ReleaseSharedLocalBackgroundServer(context.Context, SharedLocalOptions) (SharedLocalSessionRepairResult, error) {
	return SharedLocalSessionRepairResult{}, errors.New("安全释放后台共享 Codex App Server 只支持 macOS")
}

//go:build !darwin

package appserver

import "context"

// 不支持 launchd 共享 daemon 生命周期的平台不需要参与跨进程重启互斥。
func AcquireSharedDaemonUsageFence(context.Context) (func(), error) {
	return func() {}, nil
}

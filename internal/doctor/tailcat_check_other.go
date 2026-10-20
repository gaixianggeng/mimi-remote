//go:build !windows

package doctor

import "context"

// Mac 与 Linux 的辅助程序由各自安装形态管理，诊断暂不包含这一项。
func (c *Checker) tailcatCheck(context.Context) Check {
	return Check{}
}

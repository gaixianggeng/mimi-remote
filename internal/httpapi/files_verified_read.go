package httpapi

import (
	"io"
	"os"
)

// readVerifiedPreviewFile 关闭授权根之外特例的“检查—使用”窗口：解析阶段只校验了路径当时
// 指向的文件，同一用户的进程可以在此之后、读取之前把它换成指向授权外文件的符号链接、硬链接
// 或另一个文件，而按路径读取会跟随替换后的目标。这里打开后用 fd 复核仍是解析时校验过的同一个
// 普通文件（需要时再复核 owner 与链接数），读取也只从这个 fd 进行。
func readVerifiedPreviewFile(realPath string, resolved fileReadResolvedPath, maxBytes int64) ([]byte, error) {
	file, err := os.Open(realPath)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if resolved.verifiedFile == nil || !info.Mode().IsRegular() || !os.SameFile(info, resolved.verifiedFile) {
		return nil, errFilePathOutsideScope
	}
	if resolved.requireOwnedSingleLink && !fileOwnedByCurrentUserWithSingleLink(info) {
		return nil, errFilePathOutsideScope
	}
	// 多读 1 字节，让调用方的大小上限复核能发现读取期间被追加的文件。
	return io.ReadAll(io.LimitReader(file, maxBytes+1))
}

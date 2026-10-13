package httpapi

import (
	"io"
	"os"
)

// readVerifiedPreviewFile 关闭授权根之外特例的“检查—使用”窗口：解析阶段只校验了路径当时
// 指向的文件，同一用户的进程可以在此之后、读取之前把文件或它的任一上级目录换成符号链接、
// 硬链接或另一个文件，而按路径读取会跟随替换后的目标。这里从解析时确认的授权根逐级
// O_NOFOLLOW 打开 realPath，再用 fd 复核仍是解析时校验过的同一个普通文件；除非特例显式
// 放宽，还要求当前用户拥有且只有一个链接。读取只从这个 fd 进行。
func readVerifiedPreviewFile(realPath string, resolved fileReadResolvedPath, maxBytes int64) ([]byte, error) {
	// 缺少身份或授权根时一律拒绝，避免新特例漏设字段后退化为按路径读取。
	if resolved.verifiedFile == nil || resolved.trustedRoot == "" {
		return nil, errFilePathOutsideScope
	}
	file, err := openPreviewFileNoFollow(resolved.trustedRoot, realPath)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || !os.SameFile(info, resolved.verifiedFile) {
		return nil, errFilePathOutsideScope
	}
	if !resolved.relaxOwnerAndLinkCheck && !fileOwnedByCurrentUserWithSingleLink(info) {
		return nil, errFilePathOutsideScope
	}
	// 多读 1 字节，让调用方的大小上限复核能发现读取期间被追加的文件。
	return io.ReadAll(io.LimitReader(file, maxBytes+1))
}

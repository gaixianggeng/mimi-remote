//go:build !windows

package httpapi

import (
	"errors"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
)

// openPreviewFileNoFollow 从解析阶段确认的授权根开始逐级 openat，每一级都带 O_NOFOLLOW：
// 解析之后授权根或其下任何一级被换成符号链接，都会在打开时失败，而不是被跟随到授权范围外。
// root 与 realPath 都是解析掉符号链接后的路径，正常情况下沿途没有符号链接。最终文件用
// O_NONBLOCK 打开，被换成 FIFO 时不会阻塞处理器；确认是普通文件后再恢复阻塞读取。
func openPreviewFileNoFollow(root string, realPath string) (*os.File, error) {
	rel, err := filepath.Rel(root, realPath)
	if err != nil || rel == "." || rel == ".." || filepath.IsAbs(rel) ||
		strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return nil, errFilePathOutsideScope
	}
	parts := strings.Split(rel, string(filepath.Separator))

	dirFD, err := unix.Open(root, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, previewNoFollowOpenError(root, err)
	}
	for index, part := range parts {
		last := index == len(parts)-1
		flags := unix.O_RDONLY | unix.O_NOFOLLOW | unix.O_CLOEXEC
		if last {
			flags |= unix.O_NONBLOCK
		} else {
			flags |= unix.O_DIRECTORY
		}
		fd, err := unix.Openat(dirFD, part, flags, 0)
		_ = unix.Close(dirFD)
		if err != nil {
			return nil, previewNoFollowOpenError(realPath, err)
		}
		if !last {
			dirFD = fd
			continue
		}
		var stat unix.Stat_t
		if err := unix.Fstat(fd, &stat); err != nil {
			_ = unix.Close(fd)
			return nil, previewNoFollowOpenError(realPath, err)
		}
		if stat.Mode&unix.S_IFMT != unix.S_IFREG {
			_ = unix.Close(fd)
			return nil, errFilePathOutsideScope
		}
		if err := unix.SetNonblock(fd, false); err != nil {
			_ = unix.Close(fd)
			return nil, previewNoFollowOpenError(realPath, err)
		}
		return os.NewFile(uintptr(fd), realPath), nil
	}
	return nil, errFilePathOutsideScope
}

// 沿途遇到符号链接（ELOOP）或某一级不再是目录（ENOTDIR）说明解析后被替换，按越界处理；
// ENOENT、EPERM 等保留原始错误，处理器据此给出“文件不存在”或 macOS 隐私授权提示。
func previewNoFollowOpenError(path string, err error) error {
	if errors.Is(err, unix.ELOOP) || errors.Is(err, unix.ENOTDIR) {
		return errFilePathOutsideScope
	}
	return &os.PathError{Op: "open", Path: path, Err: err}
}

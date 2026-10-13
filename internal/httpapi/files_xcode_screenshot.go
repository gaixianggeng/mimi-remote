package httpapi

import (
	"os"
	"path/filepath"
	"strings"
)

// XcodeBuildMCP 的 screenshot 工具（returnFormat: "path"）把模拟器截图直接写在 Node
// os.tmpdir() 下：正常产物是 sips 压缩后的 screenshot_optimized_<uuid>.jpg，压缩失败时
// 回退为原图 screenshot_<uuid>.png；<uuid> 来自 uuid.v4()，固定为小写 8-4-4-4-12。
// 这个临时目录不属于项目、托管 Worktree 或 browse root，这里只放行能严格识别的截图产物，
// 不能把整个临时目录变成授权根。
const (
	xcodeBuildMCPScreenshotOptimizedPrefix = "screenshot_optimized_"
	xcodeBuildMCPScreenshotOriginalPrefix  = "screenshot_"
)

// 压缩版最长边只有 800px，通常几百 KB；PNG 回退是模拟器原始分辨率，最大机型也远低于该值。
var xcodeBuildMCPScreenshotMaxBytes int64 = 16 << 20

type xcodeBuildMCPScreenshot struct {
	realPath    string
	contentType string
	// info 是解析时 Lstat 校验过的文件身份；读取时必须仍是同一个文件。
	info os.FileInfo
}

// xcodeBuildMCPScreenshotContentType 返回截图文件名唯一允许的 MIME；不符合命名规则时返回空。
func xcodeBuildMCPScreenshotContentType(name string) string {
	var stem, contentType string
	switch {
	case strings.HasPrefix(name, xcodeBuildMCPScreenshotOptimizedPrefix) && strings.HasSuffix(name, ".jpg"):
		stem = strings.TrimSuffix(strings.TrimPrefix(name, xcodeBuildMCPScreenshotOptimizedPrefix), ".jpg")
		contentType = "image/jpeg"
	case strings.HasPrefix(name, xcodeBuildMCPScreenshotOriginalPrefix) && strings.HasSuffix(name, ".png"):
		stem = strings.TrimSuffix(strings.TrimPrefix(name, xcodeBuildMCPScreenshotOriginalPrefix), ".png")
		contentType = "image/png"
	default:
		return ""
	}
	if !isLowercaseCanonicalUUID(stem) {
		return ""
	}
	return contentType
}

func isLowercaseCanonicalUUID(value string) bool {
	if len(value) != 36 {
		return false
	}
	for index := 0; index < len(value); index++ {
		char := value[index]
		switch index {
		case 8, 13, 18, 23:
			if char != '-' {
				return false
			}
		default:
			if !((char >= '0' && char <= '9') || (char >= 'a' && char <= 'f')) {
				return false
			}
		}
	}
	return true
}

// resolveXcodeBuildMCPScreenshotPath 返回 (screenshot, candidate, err)。candidate 表示原始路径
// 在结构上就是临时目录直属的截图产物：绝对路径、不含 ".."、文件名严格匹配，且父目录解析
// 符号链接后正好是临时目录。此时文件缺失要保留 ENOENT，让客户端提示“文件已不存在”，
// 而不是误报为授权范围问题；其余拒绝统一按越界处理。
func resolveXcodeBuildMCPScreenshotPath(raw string, temporaryRoot string) (xcodeBuildMCPScreenshot, bool, error) {
	path := strings.TrimSpace(raw)
	root := strings.TrimSpace(temporaryRoot)
	if path == "" || root == "" || !filepath.IsAbs(path) {
		return xcodeBuildMCPScreenshot{}, false, nil
	}
	for _, part := range strings.Split(filepath.ToSlash(path), "/") {
		if part == ".." {
			return xcodeBuildMCPScreenshot{}, false, nil
		}
	}
	path = filepath.Clean(path)
	name := filepath.Base(path)
	contentType := xcodeBuildMCPScreenshotContentType(name)
	if contentType == "" {
		return xcodeBuildMCPScreenshot{}, false, nil
	}
	realRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return xcodeBuildMCPScreenshot{}, false, nil
	}
	realParent, err := filepath.EvalSymlinks(filepath.Dir(path))
	if err != nil || filepath.Clean(realParent) != filepath.Clean(realRoot) {
		return xcodeBuildMCPScreenshot{}, false, nil
	}

	info, err := os.Lstat(path)
	if err != nil {
		return xcodeBuildMCPScreenshot{}, true, err
	}
	// 文件本身不能是符号链接、硬链接或他人创建的文件；否则可信文件名可以借道指向任意内容。
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || !fileOwnedByCurrentUserWithSingleLink(info) {
		return xcodeBuildMCPScreenshot{}, true, errFilePathOutsideScope
	}
	realPath, err := filepath.EvalSymlinks(path)
	if err != nil {
		return xcodeBuildMCPScreenshot{}, true, err
	}
	if filepath.Clean(filepath.Dir(realPath)) != filepath.Clean(realRoot) || filepath.Base(realPath) != name {
		return xcodeBuildMCPScreenshot{}, true, errFilePathOutsideScope
	}
	return xcodeBuildMCPScreenshot{realPath: realPath, contentType: contentType, info: info}, true, nil
}

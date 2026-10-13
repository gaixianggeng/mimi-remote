//go:build !windows

package httpapi

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/unix"
)

// replaceDirWithSymlink 把目录挪走，在原位置放一个指向授权外目录的符号链接。
func replaceDirWithSymlink(t *testing.T, dir, outside string) {
	t.Helper()
	if err := os.Rename(dir, dir+".moved"); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, dir); err != nil {
		t.Fatal(err)
	}
}

// outsideDirWithSecret 在授权外目录中放一个与被预览文件同名、内容不同的文件。
func outsideDirWithSecret(t *testing.T, name string) string {
	t.Helper()
	dir := t.TempDir()
	content := append(append([]byte{}, testVerifiedPreviewPNG...), []byte("outside-scope")...)
	writeVerifiedPreviewTestFile(t, filepath.Join(dir, name), content)
	return dir
}

func photosDerivativeTestPath(t *testing.T) (string, string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	dir := filepath.Join(home, "Pictures", "Photos Library.photoslibrary", "resources", "derivatives", "2")
	path := filepath.Join(dir, "image.png")
	writeVerifiedPreviewTestFile(t, path, testVerifiedPreviewPNG)
	return dir, path
}

func requireOutsideScopeRead(t *testing.T, resolved fileReadResolvedPath, message string) {
	t.Helper()
	data, err := readVerifiedPreviewFile(resolved.realPath, resolved, filePreviewMaxBytes)
	if !errors.Is(err, errFilePathOutsideScope) || len(data) != 0 {
		t.Fatalf("%s：len=%d err=%v", message, len(data), err)
	}
}

// 解析通过之后，照片 derivatives 的上级目录被换成指向授权外目录的符号链接：读取必须逐级
// O_NOFOLLOW 打开，不能跟随上级目录读到授权外的同名文件。
func TestReadVerifiedPhotosDerivativeImageRejectsParentSwapAfterResolve(t *testing.T) {
	dir, path := photosDerivativeTestPath(t)
	resolved, candidate, err := resolveAllowedPhotosDerivativeImagePath(path)
	if !candidate || err != nil || resolved.realPath == "" {
		t.Fatalf("照片 derivatives 图片应先通过解析：candidate=%v err=%v", candidate, err)
	}
	replaceDirWithSymlink(t, dir, outsideDirWithSecret(t, "image.png"))
	requireOutsideScopeRead(t, resolved, "解析后上级目录被换成符号链接时必须按越界拒绝")
}

// 上级目录在 EvalSymlinks 校验之后、记录文件身份之前被替换：记录到的是授权外文件的身份，
// 读取时仍必须拒绝，不能因为 SameFile 通过就返回授权外内容。
func TestReadVerifiedPhotosDerivativeImageRejectsParentSwapDuringResolve(t *testing.T) {
	dir, path := photosDerivativeTestPath(t)
	outside := outsideDirWithSecret(t, "image.png")
	original := evalFileSymlinks
	t.Cleanup(func() { evalFileSymlinks = original })
	swapped := false
	evalFileSymlinks = func(target string) (string, error) {
		resolved, err := original(target)
		if err == nil && target == path && !swapped {
			swapped = true
			replaceDirWithSymlink(t, dir, outside)
		}
		return resolved, err
	}

	resolved, candidate, err := resolveAllowedPhotosDerivativeImagePath(path)
	if !swapped {
		t.Fatal("测试钩子没有在解析期间替换上级目录")
	}
	if !candidate || err != nil || resolved.realPath == "" {
		t.Fatalf("解析阶段只看路径字符串，应仍判定为候选：candidate=%v err=%v", candidate, err)
	}
	requireOutsideScopeRead(t, resolved, "解析期间上级目录被换成符号链接时必须按越界拒绝")
}

// 剪贴板临时目录本身在解析后被换成符号链接时同样拒绝。
func TestReadVerifiedCodexClipboardImageRejectsRootSwapAfterResolve(t *testing.T) {
	name := "codex-clipboard-9ba62714-bcfb-4693-805b-1be6e284e924.png"
	root := filepath.Join(t.TempDir(), "T")
	path := filepath.Join(root, name)
	writeVerifiedPreviewTestFile(t, path, testVerifiedPreviewPNG)
	resolved, ok := allowedCodexClipboardImagePath(path, root)
	if !ok {
		t.Fatal("剪贴板图片应先通过解析")
	}
	replaceDirWithSymlink(t, root, outsideDirWithSecret(t, name))
	requireOutsideScopeRead(t, resolved, "解析后临时目录被换成符号链接时必须按越界拒绝")
}

// 文件在解析后被换成 FIFO 时，读取必须立即拒绝，不能阻塞等待写端。
func TestReadVerifiedPreviewFileRejectsFIFOWithoutBlocking(t *testing.T) {
	_, path := photosDerivativeTestPath(t)
	resolved, candidate, err := resolveAllowedPhotosDerivativeImagePath(path)
	if !candidate || err != nil || resolved.realPath == "" {
		t.Fatalf("照片 derivatives 图片应先通过解析：candidate=%v err=%v", candidate, err)
	}
	if err := os.Remove(resolved.realPath); err != nil {
		t.Fatal(err)
	}
	if err := unix.Mkfifo(resolved.realPath, 0o600); err != nil {
		t.Skipf("当前文件系统不支持 FIFO：%v", err)
	}
	requireOutsideScopeRead(t, resolved, "被换成 FIFO 的文件必须按越界拒绝")
}

// 默认严格：没有显式放宽的特例，读取时文件必须由当前用户拥有且只有一个链接。
// 防止新特例（例如合并后的 XcodeBuildMCP 截图）漏设字段时悄悄放宽。
func TestReadVerifiedPreviewFileDefaultsToOwnerAndSingleLink(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "image.png")
	writeVerifiedPreviewTestFile(t, path, testVerifiedPreviewPNG)
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	strict := fileReadResolvedPath{realPath: path, verifiedFile: info, trustedRoot: root}
	if data, err := readVerifiedPreviewFile(path, strict, filePreviewMaxBytes); err != nil ||
		string(data) != string(testVerifiedPreviewPNG) {
		t.Fatalf("单链接文件应按原内容读取：len=%d err=%v", len(data), err)
	}

	// 同一 inode 多出一个链接后，默认严格的特例必须拒绝；照片图库这类显式放宽的特例仍可读。
	if err := os.Link(path, filepath.Join(t.TempDir(), "extra-link.png")); err != nil {
		t.Skipf("当前文件系统不支持硬链接：%v", err)
	}
	requireOutsideScopeRead(t, strict, "默认严格时多链接文件必须拒绝")
	relaxed := strict
	relaxed.relaxOwnerAndLinkCheck = true
	if data, err := readVerifiedPreviewFile(path, relaxed, filePreviewMaxBytes); err != nil ||
		string(data) != string(testVerifiedPreviewPNG) {
		t.Fatalf("显式放宽后多链接文件应可读：len=%d err=%v", len(data), err)
	}

	missingRoot := strict
	missingRoot.trustedRoot = ""
	requireOutsideScopeRead(t, missingRoot, "缺少授权根时必须拒绝，不能退化为按路径读取")
}

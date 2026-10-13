package httpapi

import (
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

var testVerifiedPreviewPNG = append(
	[]byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A},
	make([]byte, 64)...,
)

// previewFileSwap 模拟解析通过之后、读取之前，同一用户的进程替换掉已校验的文件。
type previewFileSwap struct {
	label   string
	replace func(secret, path string) error
}

func previewFileSwaps() []previewFileSwap {
	return []previewFileSwap{
		{"替换为符号链接", func(secret, path string) error {
			if err := os.Remove(path); err != nil {
				return err
			}
			return os.Symlink(secret, path)
		}},
		{"替换为硬链接", func(secret, path string) error {
			if err := os.Remove(path); err != nil {
				return err
			}
			return os.Link(secret, path)
		}},
		{"原子替换为不同 inode 的普通文件", func(secret, path string) error {
			content, err := os.ReadFile(secret)
			if err != nil {
				return err
			}
			staged := filepath.Join(filepath.Dir(path), "staged-replacement")
			if err := os.WriteFile(staged, content, 0o600); err != nil {
				return err
			}
			return os.Rename(staged, path)
		}},
	}
}

func writeVerifiedPreviewTestFile(t *testing.T, path string, content []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, content, 0o600); err != nil {
		t.Fatal(err)
	}
}

func verifiedPreviewSecret(t *testing.T) (string, []byte) {
	t.Helper()
	content := append(append([]byte{}, testVerifiedPreviewPNG...), []byte("outside-scope")...)
	path := filepath.Join(t.TempDir(), "private.png")
	writeVerifiedPreviewTestFile(t, path, content)
	return path, content
}

func TestReadVerifiedCodexClipboardImageRejectsSwapAfterResolve(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Codex 剪贴板特例只在 macOS 生效，Windows 没有 owner/硬链接校验")
	}
	name := "codex-clipboard-9ba62714-bcfb-4693-805b-1be6e284e924.png"

	t.Run("未替换", func(t *testing.T) {
		root := t.TempDir()
		path := filepath.Join(root, name)
		writeVerifiedPreviewTestFile(t, path, testVerifiedPreviewPNG)
		resolved, ok := allowedCodexClipboardImagePath(path, root)
		if !ok {
			t.Fatal("剪贴板图片应先通过解析")
		}
		data, err := readVerifiedPreviewFile(resolved.realPath, resolved, filePreviewMaxBytes)
		if err != nil || string(data) != string(testVerifiedPreviewPNG) {
			t.Fatalf("未替换的剪贴板图片应按原内容读取：len=%d err=%v", len(data), err)
		}
	})

	for _, swap := range previewFileSwaps() {
		t.Run(swap.label, func(t *testing.T) {
			root := t.TempDir()
			secret, _ := verifiedPreviewSecret(t)
			path := filepath.Join(root, name)
			writeVerifiedPreviewTestFile(t, path, testVerifiedPreviewPNG)
			resolved, ok := allowedCodexClipboardImagePath(path, root)
			if !ok {
				t.Fatal("剪贴板图片应先通过解析")
			}
			if err := swap.replace(secret, path); err != nil {
				t.Skipf("当前文件系统不支持该替换方式：%v", err)
			}
			data, err := readVerifiedPreviewFile(resolved.realPath, resolved, filePreviewMaxBytes)
			if !errors.Is(err, errFilePathOutsideScope) || len(data) != 0 {
				t.Fatalf("解析后被替换的剪贴板图片必须按越界拒绝：len=%d err=%v", len(data), err)
			}
		})
	}
}

func TestAllowedCodexClipboardImagePathRejectsHardLinkAtResolve(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Codex 剪贴板特例只在 macOS 生效，Windows 没有 owner/硬链接校验")
	}
	root := t.TempDir()
	secret, _ := verifiedPreviewSecret(t)
	path := filepath.Join(root, "codex-clipboard-15031bdc-111a-4669-b3e6-4ef5f2094829.png")
	if err := os.Link(secret, path); err != nil {
		t.Skipf("当前文件系统不支持硬链接：%v", err)
	}
	if _, ok := allowedCodexClipboardImagePath(path, root); ok {
		t.Fatal("解析时就是硬链接的剪贴板文件名可能指向授权外内容，不应放行")
	}
}

func TestFileReadRejectsHardLinkedCodexClipboardImageOnMacOS(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("Codex 桌面剪贴板临时路径只在 macOS 放行")
	}
	server := newTestServer(t)
	secret, _ := verifiedPreviewSecret(t)
	path := filepath.Join(os.TempDir(), "codex-clipboard-6f1d2c3b-4a5e-4f60-9b7c-8d9e0a1b2c3d.png")
	t.Cleanup(func() { _ = os.Remove(path) })
	if err := os.Link(secret, path); err != nil {
		t.Skipf("当前文件系统不支持硬链接：%v", err)
	}
	rec, _ := readPreviewFile(t, server.handler, path)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("硬链接伪装的剪贴板图片应按越界拒绝，got=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestReadVerifiedPhotosDerivativeImageRejectsSwapAfterResolve(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("照片图库 derivatives 特例面向 macOS；Windows 的符号链接与硬链接替换不在此覆盖")
	}
	setup := func(t *testing.T) string {
		home := t.TempDir()
		t.Setenv("HOME", home)
		path := filepath.Join(home, "Pictures", "Photos Library.photoslibrary", "resources", "derivatives", "2", "image.png")
		writeVerifiedPreviewTestFile(t, path, testVerifiedPreviewPNG)
		return path
	}

	t.Run("未替换", func(t *testing.T) {
		path := setup(t)
		resolved, candidate, err := resolveAllowedPhotosDerivativeImagePath(path)
		if !candidate || err != nil || resolved.realPath == "" || resolved.verifiedFile == nil {
			t.Fatalf("照片 derivatives 图片应先通过解析：candidate=%v err=%v", candidate, err)
		}
		data, err := readVerifiedPreviewFile(resolved.realPath, resolved, filePreviewMaxBytes)
		if err != nil || string(data) != string(testVerifiedPreviewPNG) {
			t.Fatalf("未替换的照片 derivatives 图片应按原内容读取：len=%d err=%v", len(data), err)
		}
	})

	for _, swap := range previewFileSwaps() {
		t.Run(swap.label, func(t *testing.T) {
			path := setup(t)
			secret, _ := verifiedPreviewSecret(t)
			resolved, candidate, err := resolveAllowedPhotosDerivativeImagePath(path)
			if !candidate || err != nil || resolved.realPath == "" {
				t.Fatalf("照片 derivatives 图片应先通过解析：candidate=%v err=%v", candidate, err)
			}
			if err := swap.replace(secret, resolved.realPath); err != nil {
				t.Skipf("当前文件系统不支持该替换方式：%v", err)
			}
			data, err := readVerifiedPreviewFile(resolved.realPath, resolved, filePreviewMaxBytes)
			if !errors.Is(err, errFilePathOutsideScope) || len(data) != 0 {
				t.Fatalf("解析后被替换的照片 derivatives 图片必须按越界拒绝：len=%d err=%v", len(data), err)
			}
		})
	}
}

func TestReadVerifiedPreviewFileRejectsMissingIdentity(t *testing.T) {
	path := filepath.Join(t.TempDir(), "image.png")
	writeVerifiedPreviewTestFile(t, path, testVerifiedPreviewPNG)
	data, err := readVerifiedPreviewFile(path, fileReadResolvedPath{realPath: path}, filePreviewMaxBytes)
	if !errors.Is(err, errFilePathOutsideScope) || len(data) != 0 {
		t.Fatalf("缺少解析时文件身份时必须拒绝：len=%d err=%v", len(data), err)
	}
}

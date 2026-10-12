package httpapi

import (
	"errors"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

const (
	testXcodeScreenshotUUID      = "9ba62714-bcfb-4693-805b-1be6e284e924"
	testXcodeScreenshotOtherUUID = "15031bdc-111a-4669-b3e6-4ef5f2094829"
)

var (
	testXcodeScreenshotJPEG = append([]byte{0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 'J', 'F', 'I', 'F', 0x00}, make([]byte, 64)...)
	testXcodeScreenshotPNG  = append([]byte{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a}, make([]byte, 64)...)
)

func writeTestXcodeScreenshot(t *testing.T, dir string, name string, data []byte) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestXcodeBuildMCPScreenshotContentTypeMatchesToolNaming(t *testing.T) {
	cases := map[string]string{
		"screenshot_optimized_" + testXcodeScreenshotUUID + ".jpg": "image/jpeg",
		"screenshot_" + testXcodeScreenshotUUID + ".png":           "image/png",
		// 以下均不是 XcodeBuildMCP 的实际产物，必须拒绝。
		"screenshot_optimized_" + testXcodeScreenshotUUID + ".png":             "",
		"screenshot_" + testXcodeScreenshotUUID + ".jpg":                       "",
		"screenshot_optimized_" + testXcodeScreenshotUUID + ".jpeg":            "",
		"screenshot_optimized_" + testXcodeScreenshotUUID + ".JPG":             "",
		"screenshot_optimized_" + testXcodeScreenshotUUID + ".jpg.txt":         "",
		"screenshot_optimized_9BA62714-BCFB-4693-805B-1BE6E284E924.jpg":        "",
		"screenshot_optimized_9ba62714bcfb4693805b1be6e284e924.jpg":            "",
		"screenshot_optimized_9ba62714-bcfb-4693-805b-1be6e284e92.jpg":         "",
		"screenshot_optimized_9ba62714_bcfb-4693-805b-1be6e284e924.jpg":        "",
		"screenshot_optimized_9ba62714-bcfb-4693-805b-1be6e284e92g.jpg":        "",
		"simulator_screenshot_9BA62714-BCFB-4693-805B-1BE6E284E924.png":        "",
		"xscreenshot_" + testXcodeScreenshotUUID + ".png":                      "",
		"screenshot_" + testXcodeScreenshotUUID:                                "",
		"codex-clipboard-" + testXcodeScreenshotUUID + ".png":                  "",
		"screenshot_optimized_" + testXcodeScreenshotUUID + "_copy.jpg":        "",
		"screenshot_optimized_" + testXcodeScreenshotUUID + ".jpg/":            "",
		"screenshot_optimized_" + testXcodeScreenshotUUID + "-" + "x" + ".jpg": "",
	}
	for name, want := range cases {
		if got := xcodeBuildMCPScreenshotContentType(name); got != want {
			t.Errorf("文件名 %q 应识别为 %q，got=%q", name, want, got)
		}
	}
}

func TestResolveXcodeBuildMCPScreenshotPathAllowsOnlyDirectToolArtifacts(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("XcodeBuildMCP 截图特例只在 macOS 生效，Windows 没有 owner/硬链接校验")
	}
	root := t.TempDir()
	realRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		t.Fatal(err)
	}
	optimizedName := "screenshot_optimized_" + testXcodeScreenshotUUID + ".jpg"
	optimized := writeTestXcodeScreenshot(t, root, optimizedName, testXcodeScreenshotJPEG)
	original := writeTestXcodeScreenshot(t, root, "screenshot_"+testXcodeScreenshotUUID+".png", testXcodeScreenshotPNG)

	got, candidate, err := resolveXcodeBuildMCPScreenshotPath(optimized, root)
	if !candidate || err != nil || got.realPath != filepath.Join(realRoot, optimizedName) || got.contentType != "image/jpeg" {
		t.Fatalf("压缩版截图应放行：got=%+v candidate=%v err=%v", got, candidate, err)
	}
	if got, candidate, err := resolveXcodeBuildMCPScreenshotPath(original, root); !candidate || err != nil || got.contentType != "image/png" {
		t.Fatalf("PNG 回退截图应放行：got=%+v candidate=%v err=%v", got, candidate, err)
	}

	// 父目录经符号链接指向临时目录时（例如 macOS 的 /var -> /private/var），按解析后的真实目录判定。
	aliasParent := t.TempDir()
	alias := filepath.Join(aliasParent, "tmp-alias")
	requireTestSymlink(t, root, alias)
	if got, candidate, err := resolveXcodeBuildMCPScreenshotPath(filepath.Join(alias, optimizedName), root); !candidate || err != nil || got.realPath != filepath.Join(realRoot, optimizedName) {
		t.Fatalf("经符号链接别名访问的同一截图应解析为真实路径：got=%+v candidate=%v err=%v", got, candidate, err)
	}

	missing := filepath.Join(root, "screenshot_optimized_"+testXcodeScreenshotOtherUUID+".jpg")
	if _, candidate, err := resolveXcodeBuildMCPScreenshotPath(missing, root); !candidate || !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("已被清理的截图应保留 ENOENT 而不是报越界：candidate=%v err=%v", candidate, err)
	}
}

func TestResolveXcodeBuildMCPScreenshotPathRejectsUnsafeVariants(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("XcodeBuildMCP 截图特例只在 macOS 生效，Windows 没有 owner/硬链接校验")
	}
	root := t.TempDir()
	validName := "screenshot_optimized_" + testXcodeScreenshotUUID + ".jpg"
	writeTestXcodeScreenshot(t, root, validName, testXcodeScreenshotJPEG)
	otherName := "screenshot_optimized_" + testXcodeScreenshotOtherUUID + ".jpg"

	outsideDir := t.TempDir()
	outsideSecret := writeTestXcodeScreenshot(t, outsideDir, "secret.jpg", testXcodeScreenshotJPEG)
	writeTestXcodeScreenshot(t, outsideDir, otherName, testXcodeScreenshotJPEG)

	nested := filepath.Join(root, "nested")
	if err := os.Mkdir(nested, 0o700); err != nil {
		t.Fatal(err)
	}
	writeTestXcodeScreenshot(t, nested, otherName, testXcodeScreenshotJPEG)

	similarPrefix := root + "-evil"
	if err := os.Mkdir(similarPrefix, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(similarPrefix) })
	writeTestXcodeScreenshot(t, similarPrefix, otherName, testXcodeScreenshotJPEG)

	notCandidates := map[string]string{
		"同目录普通文件":     writeTestXcodeScreenshot(t, root, "notes.txt", []byte("secret")),
		"同目录其他图片":     writeTestXcodeScreenshot(t, root, "photo.jpg", testXcodeScreenshotJPEG),
		"相似截图前缀":      writeTestXcodeScreenshot(t, root, "simulator_screenshot_9BA62714-BCFB-4693-805B-1BE6E284E924.png", testXcodeScreenshotPNG),
		"临时目录之外的同名文件": filepath.Join(outsideDir, otherName),
		"临时目录子目录":     filepath.Join(nested, otherName),
		"相似前缀目录":      filepath.Join(similarPrefix, otherName),
		"..穿越回临时目录":   filepath.Join(root, "nested") + "/../" + validName,
		"..穿越出临时目录":   root + "/../" + filepath.Base(outsideDir) + "/" + otherName,
		"相对路径":        validName,
		"临时目录之外的图片":   outsideSecret,
	}
	for label, path := range notCandidates {
		if got, candidate, err := resolveXcodeBuildMCPScreenshotPath(path, root); candidate || got.realPath != "" || err != nil {
			t.Errorf("%s 不应进入截图特例：got=%+v candidate=%v err=%v", label, got, candidate, err)
		}
	}

	symlinkOutside := filepath.Join(root, "screenshot_"+testXcodeScreenshotOtherUUID+".png")
	requireTestSymlink(t, outsideSecret, symlinkOutside)
	symlinkInside := filepath.Join(root, "screenshot_optimized_aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee.jpg")
	requireTestSymlink(t, filepath.Join(root, validName), symlinkInside)
	hardLinkSource := writeTestXcodeScreenshot(t, outsideDir, "private.png", testXcodeScreenshotPNG)
	hardLink := filepath.Join(root, "screenshot_aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee.png")
	if err := os.Link(hardLinkSource, hardLink); err != nil {
		t.Fatal(err)
	}
	directory := filepath.Join(root, "screenshot_bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee.png")
	if err := os.Mkdir(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	rejected := map[string]string{
		"符号链接指向授权外":   symlinkOutside,
		"符号链接指向同目录截图": symlinkInside,
		"硬链接借用可信文件名":  hardLink,
		"同名目录":        directory,
	}
	for label, path := range rejected {
		got, candidate, err := resolveXcodeBuildMCPScreenshotPath(path, root)
		if !candidate || got.realPath != "" || !errors.Is(err, errFilePathOutsideScope) {
			t.Errorf("%s 应按越界拒绝：got=%+v candidate=%v err=%v", label, got, candidate, err)
		}
	}
}

func TestFileReadXcodeBuildMCPScreenshotOnMacOS(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("XcodeBuildMCP 截图临时路径只在 macOS 放行")
	}
	root := t.TempDir()
	realRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		t.Fatal(err)
	}
	outsideDir := t.TempDir()
	similarPrefix := root + "-evil"
	if err := os.Mkdir(similarPrefix, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(similarPrefix) })
	t.Setenv("TMPDIR", root)
	server := newTestServer(t)

	jpegName := "screenshot_optimized_" + testXcodeScreenshotUUID + ".jpg"
	jpegPath := writeTestXcodeScreenshot(t, root, jpegName, testXcodeScreenshotJPEG)
	rec, body := readPreviewFile(t, server.handler, jpegPath)
	if rec.Code != http.StatusOK {
		t.Fatalf("XcodeBuildMCP 截图应可预览，got=%d body=%s", rec.Code, rec.Body.String())
	}
	if body["path"] != filepath.Join(realRoot, jpegName) || body["name"] != jpegName || body["content_type"] != "image/jpeg" {
		t.Fatalf("响应应返回真实路径并按文件头确认 JPEG：%v", body)
	}
	pngPath := writeTestXcodeScreenshot(t, root, "screenshot_"+testXcodeScreenshotUUID+".png", testXcodeScreenshotPNG)
	if rec, body := readPreviewFile(t, server.handler, pngPath); rec.Code != http.StatusOK || body["content_type"] != "image/png" {
		t.Fatalf("PNG 回退截图应可预览，got=%d body=%s", rec.Code, rec.Body.String())
	}

	otherName := "screenshot_optimized_" + testXcodeScreenshotOtherUUID + ".jpg"
	outsideSecret := writeTestXcodeScreenshot(t, outsideDir, "secret.jpg", testXcodeScreenshotJPEG)
	symlinkOutside := filepath.Join(root, "screenshot_optimized_aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee.jpg")
	requireTestSymlink(t, outsideSecret, symlinkOutside)
	outsideScope := map[string]string{
		"临时目录普通文件":    writeTestXcodeScreenshot(t, root, "notes.txt", []byte("secret")),
		"临时目录其他图片":    writeTestXcodeScreenshot(t, root, "photo.jpg", testXcodeScreenshotJPEG),
		"符号链接指向授权外":   symlinkOutside,
		"..穿越回临时目录":   root + "/nested/../" + jpegName,
		"相似前缀目录":      writeTestXcodeScreenshot(t, similarPrefix, otherName, testXcodeScreenshotJPEG),
		"临时目录之外的同名文件": writeTestXcodeScreenshot(t, outsideDir, otherName, testXcodeScreenshotJPEG),
	}
	for label, path := range outsideScope {
		rec, _ := readPreviewFile(t, server.handler, path)
		if rec.Code != http.StatusForbidden || decodeJSON(t, rec)["code"] != fileReadCodePathOutsideScope {
			t.Errorf("%s 应按越界拒绝，got=%d body=%s", label, rec.Code, rec.Body.String())
		}
	}

	missing := filepath.Join(root, "screenshot_optimized_cccccccc-bbbb-4ccc-8ddd-eeeeeeeeeeee.jpg")
	rec, _ = readPreviewFile(t, server.handler, missing)
	if rec.Code != http.StatusForbidden || decodeJSON(t, rec)["code"] != fileReadCodeNotFound {
		t.Fatalf("已被清理的截图应明确报告文件不存在，got=%d body=%s", rec.Code, rec.Body.String())
	}

	notImage := writeTestXcodeScreenshot(t, root, "screenshot_optimized_dddddddd-bbbb-4ccc-8ddd-eeeeeeeeeeee.jpg", []byte("plain text with a jpg name"))
	if rec, _ := readPreviewFile(t, server.handler, notImage); rec.Code != http.StatusBadRequest {
		t.Fatalf("只有截图文件名、没有图片文件头的内容应被拒绝，got=%d body=%s", rec.Code, rec.Body.String())
	}
	mismatched := writeTestXcodeScreenshot(t, root, "screenshot_optimized_eeeeeeee-bbbb-4ccc-8ddd-eeeeeeeeeeee.jpg", testXcodeScreenshotPNG)
	if rec, _ := readPreviewFile(t, server.handler, mismatched); rec.Code != http.StatusBadRequest {
		t.Fatalf("文件头与截图命名约定的格式不一致时应拒绝，got=%d body=%s", rec.Code, rec.Body.String())
	}

	previousLimit := xcodeBuildMCPScreenshotMaxBytes
	xcodeBuildMCPScreenshotMaxBytes = int64(len(testXcodeScreenshotJPEG)) - 1
	t.Cleanup(func() { xcodeBuildMCPScreenshotMaxBytes = previousLimit })
	if rec, _ := readPreviewFile(t, server.handler, jpegPath); rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("超过截图大小上限时应拒绝，got=%d body=%s", rec.Code, rec.Body.String())
	}
}

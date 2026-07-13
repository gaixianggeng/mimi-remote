package httpapi

import (
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func readPreviewFile(t *testing.T, handler http.Handler, path string) (*httptest.ResponseRecorder, map[string]any) {
	t.Helper()

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/files/read", map[string]string{
		"path": path,
	}))
	if rec.Code != http.StatusOK {
		return rec, nil
	}
	return rec, decodeJSON(t, rec)
}

func TestFileReadReturnsAllowedFilePayload(t *testing.T) {
	server := newTestServer(t)
	projectDir := configuredProjectPath(t, server.handler)
	filePath := filepath.Join(projectDir, "notes.txt")
	if err := os.WriteFile(filePath, []byte("hello\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	rec, body := readPreviewFile(t, server.handler, filePath)
	if rec.Code != http.StatusOK {
		t.Fatalf("授权文件应可读取，got=%d body=%s", rec.Code, rec.Body.String())
	}
	realPath, err := filepath.EvalSymlinks(filePath)
	if err != nil {
		t.Fatal(err)
	}
	if body["path"] != realPath || body["name"] != "notes.txt" {
		t.Fatalf("响应应包含真实路径和文件名：%v", body)
	}
	if body["size"] != float64(len("hello\n")) {
		t.Fatalf("响应 size 不正确：%v", body)
	}
	if !strings.HasPrefix(body["content_type"].(string), "text/plain") {
		t.Fatalf("notes.txt 应识别为普通文本：%v", body["content_type"])
	}
	data, err := base64.StdEncoding.DecodeString(body["content_base64"].(string))
	if err != nil {
		t.Fatalf("content_base64 应可解码：%v", err)
	}
	if string(data) != "hello\n" {
		t.Fatalf("文件内容不正确：%q", string(data))
	}
}

func TestFileReadRejectsOutsidePathWithoutLeakingDetails(t *testing.T) {
	server := newTestServer(t)
	outside := filepath.Join(t.TempDir(), "secret.txt")
	if err := os.WriteFile(outside, []byte("secret"), 0o644); err != nil {
		t.Fatal(err)
	}

	rec, _ := readPreviewFile(t, server.handler, outside)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("allowlist 外文件应被拒绝，got=%d body=%s", rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), outside) {
		t.Fatalf("拒绝响应不应泄漏外部路径：%s", rec.Body.String())
	}
}

func TestFileReadAllowsPhotosDerivativeImage(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	server := newTestServer(t)
	photoDir := filepath.Join(home, "Pictures", "Photos Library.photoslibrary", "resources", "derivatives", "2")
	if err := os.MkdirAll(photoDir, 0o755); err != nil {
		t.Fatal(err)
	}
	imagePath := filepath.Join(photoDir, "screen shot.jpeg")
	imageBytes := []byte{0xff, 0xd8, 0xff, 0xd9}
	if err := os.WriteFile(imagePath, imageBytes, 0o644); err != nil {
		t.Fatal(err)
	}

	rec, body := readPreviewFile(t, server.handler, imagePath)
	if rec.Code != http.StatusOK {
		t.Fatalf("照片库 derivatives 图片应可读取，got=%d body=%s", rec.Code, rec.Body.String())
	}
	realPath, err := filepath.EvalSymlinks(imagePath)
	if err != nil {
		t.Fatal(err)
	}
	if body["path"] != realPath || body["name"] != "screen shot.jpeg" {
		t.Fatalf("响应应包含照片真实路径和文件名：%v", body)
	}
	if !strings.HasPrefix(body["content_type"].(string), "image/jpeg") {
		t.Fatalf("照片库 jpeg 应识别为图片：%v", body["content_type"])
	}
	data, err := base64.StdEncoding.DecodeString(body["content_base64"].(string))
	if err != nil {
		t.Fatalf("content_base64 应可解码：%v", err)
	}
	if string(data) != string(imageBytes) {
		t.Fatalf("文件内容不正确：%v", data)
	}
}

func TestFileReadRejectsPhotosLibraryOutsideDerivatives(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	server := newTestServer(t)
	photoDir := filepath.Join(home, "Pictures", "Photos Library.photoslibrary", "originals")
	if err := os.MkdirAll(photoDir, 0o755); err != nil {
		t.Fatal(err)
	}
	imagePath := filepath.Join(photoDir, "original.jpeg")
	if err := os.WriteFile(imagePath, []byte{0xff, 0xd8, 0xff, 0xd9}, 0o644); err != nil {
		t.Fatal(err)
	}

	rec, _ := readPreviewFile(t, server.handler, imagePath)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("非 derivatives 照片库文件应被拒绝，got=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestFileReadRejectsOutsideImagePath(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	server := newTestServer(t)
	outside := filepath.Join(t.TempDir(), "outside.jpeg")
	if err := os.WriteFile(outside, []byte{0xff, 0xd8, 0xff, 0xd9}, 0o644); err != nil {
		t.Fatal(err)
	}

	rec, _ := readPreviewFile(t, server.handler, outside)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("普通外部图片仍应被拒绝，got=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestFileReadRejectsDirectoryPath(t *testing.T) {
	server := newTestServer(t)
	projectDir := configuredProjectPath(t, server.handler)

	rec, _ := readPreviewFile(t, server.handler, projectDir)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("目录不能作为文件预览，got=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestFileReadRejectsLargeFile(t *testing.T) {
	previousLimit := filePreviewMaxBytes
	filePreviewMaxBytes = 4
	t.Cleanup(func() {
		filePreviewMaxBytes = previousLimit
	})

	server := newTestServer(t)
	projectDir := configuredProjectPath(t, server.handler)
	filePath := filepath.Join(projectDir, "large.txt")
	if err := os.WriteFile(filePath, []byte("12345"), 0o644); err != nil {
		t.Fatal(err)
	}

	rec, _ := readPreviewFile(t, server.handler, filePath)
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("超限文件应被拒绝，got=%d body=%s", rec.Code, rec.Body.String())
	}
}

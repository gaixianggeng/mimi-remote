package doctor

import (
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

const fileAccessPreflightName = "file-access-preflight"

type fileAccessTarget struct {
	path          string
	missingIsOkay bool
}

type fileAccessFailure struct {
	path string
	err  error
}

type fileAccessPermissionDomain struct {
	name  string
	label string
	path  string
}

// StartFileAccessPreflight 必须在 serve 的其他运行时组件之前调用。探测放在单独 goroutine：
// macOS 首次弹出 TCC 对话框时，文件系统调用可能等待用户决定，但 HTTP 服务仍应恢复，
// 这样人不在 Mac 前时不会因为一个待处理弹窗导致整个远程控制面离线。
func (c *Checker) StartFileAccessPreflight() {
	if runtime.GOOS != "darwin" {
		return
	}
	c.fileAccessMu.Lock()
	if c.fileAccessPreflightStarted {
		c.fileAccessMu.Unlock()
		return
	}
	c.fileAccessPreflightStarted = true
	c.fileAccessPreflight = Check{
		Name:    fileAccessPreflightName,
		OK:      false,
		Message: "启动文件权限预检正在进行；若 macOS 弹出提示，请在 Mac 上允许访问",
		Fix:     fileAccessPreflightFix(),
	}
	c.fileAccessMu.Unlock()

	go func() {
		check, failures := runFileAccessPreflight(c.cfg, c.registry, userHomeDir(), true)
		c.mergeStartupFileAccessPreflight(check)

		if len(failures) == 0 {
			log.Printf("agentd startup file access preflight ok: %s", check.Message)
			return
		}
		for _, failure := range failures {
			log.Printf("agentd startup file access preflight blocked path=%q error=%v", failure.path, failure.err)
		}
	}()
}

func (c *Checker) mergeStartupFileAccessPreflight(check Check) {
	c.fileAccessMu.Lock()
	defer c.fileAccessMu.Unlock()
	// 按需探测已经确认的失败比启动预检成功更新、更接近真实读取。
	// 无论两个 goroutine 谁先完成，启动结果都不能覆盖该失败。
	for _, failed := range c.fileAccessRequestedDomains {
		if failed {
			return
		}
	}
	c.fileAccessPreflight = check
}

func (c *Checker) fileAccessPreflightCheck() Check {
	c.fileAccessMu.RLock()
	defer c.fileAccessMu.RUnlock()
	return c.fileAccessPreflight
}

// RequestFileAccess 在文件读取已被 macOS 拒绝后，异步探测对应的标准目录。
// 探测只用于触发系统文件夹授权提示并把结果写进 doctor，不会修改 browse_roots，
// 也不会开放远程授权入口。返回的权限域名用于客户端提示；第二个返回值表示已触发探测。
func (c *Checker) RequestFileAccess(path string) (string, bool) {
	if c == nil || runtime.GOOS != "darwin" {
		return "", false
	}
	domain, ok := c.requestFileAccess(path, userHomeDir(), probeDirectoryAccess)
	if !ok {
		return "other", false
	}
	return domain, true
}

func (c *Checker) requestFileAccess(path string, home string, probe func(string) error) (string, bool) {
	domain, ok := standardFileAccessPermissionDomain(path, home)
	if !ok {
		return "", false
	}
	c.fileAccessMu.Lock()
	if c.fileAccessRequestedDomains == nil {
		c.fileAccessRequestedDomains = make(map[string]bool)
	}
	if _, exists := c.fileAccessRequestedDomains[domain.name]; exists {
		c.fileAccessMu.Unlock()
		return domain.name, true
	}
	// false 表示已触发且尚未确认失败；map 键本身负责进程内去重。
	c.fileAccessRequestedDomains[domain.name] = false
	c.fileAccessMu.Unlock()

	go func() {
		err := probe(domain.path)
		c.fileAccessMu.Lock()
		defer c.fileAccessMu.Unlock()
		if err == nil {
			return
		}
		c.fileAccessRequestedDomains[domain.name] = true
		c.fileAccessPreflightStarted = true
		c.fileAccessPreflight = Check{
			Name:    fileAccessPreflightName,
			OK:      false,
			Level:   "warning",
			Message: fmt.Sprintf("macOS 拒绝访问%s", domain.label),
			Fix:     fileAccessPreflightFix(),
		}
		log.Printf("agentd on-demand file access probe blocked domain=%q error=%v", domain.name, err)
	}()
	return domain.name, true
}

// standardFileAccessPermissionDomain 只识别 macOS 分别管理的标准位置：桌面、文稿、下载，
// 以及 Pictures 下的 .photoslibrary bundle。普通目录不会被扩大成权限域。
func standardFileAccessPermissionDomain(path string, home string) (fileAccessPermissionDomain, bool) {
	abs, err := filepath.Abs(strings.TrimSpace(path))
	if err != nil || strings.TrimSpace(home) == "" {
		return fileAccessPermissionDomain{}, false
	}
	picturesRoot := filepath.Join(home, "Pictures")
	if relative, err := filepath.Rel(picturesRoot, abs); err == nil &&
		relative != ".." && !strings.HasPrefix(relative, ".."+string(os.PathSeparator)) {
		parts := strings.Split(filepath.Clean(relative), string(os.PathSeparator))
		for index, part := range parts {
			if strings.HasSuffix(strings.ToLower(part), ".photoslibrary") {
				bundleRoot := filepath.Join(append([]string{picturesRoot}, parts[:index+1]...)...)
				return fileAccessPermissionDomain{name: "photos_library", label: "照片图库", path: bundleRoot}, true
			}
		}
	}
	for _, candidate := range []struct {
		name  string
		label string
		dir   string
	}{
		{name: "desktop", label: "“桌面”文件夹", dir: "Desktop"},
		{name: "documents", label: "“文稿”文件夹", dir: "Documents"},
		{name: "downloads", label: "“下载”文件夹", dir: "Downloads"},
	} {
		root := filepath.Join(home, candidate.dir)
		if pathContains(root, abs) {
			return fileAccessPermissionDomain{name: candidate.name, label: candidate.label, path: root}, true
		}
	}
	return fileAccessPermissionDomain{}, false
}

func runFileAccessPreflight(cfg config.Config, registry *projects.Registry, home string, darwin bool) (Check, []fileAccessFailure) {
	targets := fileAccessPreflightTargets(cfg, registry, home, darwin)
	probed := 0
	failures := make([]fileAccessFailure, 0)
	for _, target := range targets {
		err := probeDirectoryAccess(target.path)
		if target.missingIsOkay && errors.Is(err, os.ErrNotExist) {
			continue
		}
		probed++
		if err != nil {
			failures = append(failures, fileAccessFailure{path: target.path, err: err})
		}
	}

	if len(failures) == 0 {
		return Check{
			Name:    fileAccessPreflightName,
			OK:      true,
			Message: fmt.Sprintf("启动时已主动预检 %d 个配置目录和 macOS 受保护目录", probed),
		}, nil
	}

	blocked := make([]string, 0, len(failures))
	for _, failure := range failures {
		blocked = append(blocked, failure.path)
	}
	return Check{
		Name:    fileAccessPreflightName,
		OK:      false,
		Message: fmt.Sprintf("启动权限预检发现 %d 个不可访问目录：%s", len(failures), strings.Join(blocked, "、")),
		Fix:     fileAccessPreflightFix(),
	}, failures
}

func fileAccessPreflightTargets(cfg config.Config, registry *projects.Registry, home string, darwin bool) []fileAccessTarget {
	targets := make([]fileAccessTarget, 0, len(cfg.BrowseRoots)+len(cfg.ScanRoots)+len(registry.List())+4)
	seen := map[string]bool{}
	add := func(path string, missingIsOkay bool) {
		value := strings.TrimSpace(path)
		if value == "" {
			return
		}
		abs, err := filepath.Abs(value)
		if err != nil {
			abs = filepath.Clean(value)
		}
		if seen[abs] {
			return
		}
		seen[abs] = true
		targets = append(targets, fileAccessTarget{path: abs, missingIsOkay: missingIsOkay})
	}

	for _, root := range cfg.BrowseRoots {
		add(root, false)
		if !darwin {
			continue
		}
		if pathContains(root, home) {
			// Home 顶层可读不代表这些 TCC 保护域已授权；只读取一个目录项，
			// 足以尽早触发系统提示，又不会递归扫描或读取文件内容。
			for _, name := range []string{"Desktop", "Documents", "Downloads"} {
				add(filepath.Join(home, name), true)
			}
		}
		photosLibrary := filepath.Join(home, "Pictures", "Photos Library.photoslibrary")
		if pathContains(root, photosLibrary) {
			// 照片图库（.photoslibrary）是独立的 TCC 保护 bundle：路径能 stat、却无法
			// open/read，缺少完全磁盘访问时 iPad 端预览图片会以 403 失败。提前预检可让
			// /api/doctor 直接报出“需要完全磁盘访问”。Pictures 单独作为 browse root
			// 时也必须覆盖，不能只处理整个 Home 被授权的情况。
			add(photosLibrary, true)
		}
	}
	for _, root := range cfg.ScanRoots {
		add(root, false)
	}
	for _, project := range registry.List() {
		add(project.RealPath, false)
	}
	if cfg.WorktreesRoot != "" {
		add(cfg.WorktreesRoot, true)
	}
	return targets
}

func probeDirectoryAccess(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	defer directory.Close()
	_, err = directory.Readdirnames(1)
	if errors.Is(err, io.EOF) {
		return nil
	}
	return err
}

func pathContains(root string, child string) bool {
	root = strings.TrimSpace(root)
	child = strings.TrimSpace(child)
	if root == "" || child == "" {
		return false
	}
	rootAbs, err := filepath.Abs(root)
	if err != nil {
		return false
	}
	childAbs, err := filepath.Abs(child)
	if err != nil {
		return false
	}
	relative, err := filepath.Rel(rootAbs, childAbs)
	return err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(os.PathSeparator))
}

func userHomeDir() string {
	home, _ := os.UserHomeDir()
	return home
}

func fileAccessPreflightFix() string {
	return "请允许 macOS 文件夹提示；需要无人值守访问整个 Home 或其他 App 数据时，在系统设置 → 隐私与安全性 → 完全磁盘访问中添加稳定签名的 agentd"
}

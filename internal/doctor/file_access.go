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
		c.fileAccessMu.Lock()
		c.fileAccessPreflight = check
		c.fileAccessMu.Unlock()

		if len(failures) == 0 {
			log.Printf("agentd startup file access preflight ok: %s", check.Message)
			return
		}
		for _, failure := range failures {
			log.Printf("agentd startup file access preflight blocked path=%q error=%v", failure.path, failure.err)
		}
	}()
}

func (c *Checker) fileAccessPreflightCheck() Check {
	c.fileAccessMu.RLock()
	defer c.fileAccessMu.RUnlock()
	return c.fileAccessPreflight
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
		if darwin && pathContains(root, home) {
			// Home 顶层可读不代表这些 TCC 保护域已授权；只读取一个目录项，
			// 足以尽早触发系统提示，又不会递归扫描或读取文件内容。
			for _, name := range []string{"Desktop", "Documents", "Downloads"} {
				add(filepath.Join(home, name), true)
			}
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

package httpapi

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"
)

// 会话引用授权：AI 常把截图、出图、报告写进系统临时目录（/tmp、/var/tmp、$TMPDIR，以及
// Claude 每个会话的临时目录），再在回复里写出路径。临时目录是多进程共享的落脚点，不能整体
// 加入 browse_roots；这里只放行“已授权会话里 AI 自己提到过的那个文件”。
//
//   - 证据只来自 gateway 已经按 thread 授权、即将转发给客户端的 AI 产出：助手正文里 iOS 会识别
//     成 chip 的路径、imageView、imageGeneration 落盘路径、fileChange。用户消息和工具输出不算。
//   - 只登记临时目录内的路径；读取时请求路径须与登记路径（Clean 后）完全一致，再按临时目录
//     特例的严格规则核对文件本身，并从临时目录根逐级 O_NOFOLLOW 读取。
//   - 授权只存在内存里，重新加载会话时刷新；agentd 重启后需要重新打开会话。
var (
	sessionFileGrantTTL        = 7 * 24 * time.Hour
	sessionFileGrantMaxEntries = 4096
)

type sessionFileGrantStore struct {
	mu       sync.Mutex
	lastSeen map[string]time.Time
	// roots 是临时目录的原始写法；每次使用时惰性 canonical 化，与 browse_roots 的处理一致。
	roots      []string
	ttl        time.Duration
	maxEntries int
	now        func() time.Time
}

func newSessionFileGrantStore() *sessionFileGrantStore {
	if runtime.GOOS == "windows" {
		// Windows 没有逐级 O_NOFOLLOW 读取，临时目录特例一律不开放（见 files_verified_open_windows.go）。
		return nil
	}
	return newSessionFileGrantStoreWithRoots([]string{"/tmp", "/var/tmp", os.TempDir()})
}

func newSessionFileGrantStoreWithRoots(roots []string) *sessionFileGrantStore {
	return &sessionFileGrantStore{
		lastSeen:   map[string]time.Time{},
		roots:      roots,
		ttl:        sessionFileGrantTTL,
		maxEntries: sessionFileGrantMaxEntries,
		now:        time.Now,
	}
}

// sessionFileGrantPath 把原始路径整理成登记与比对共用的形式。不接受相对路径和含 ".." 的路径：
// 精确授权不应依赖词法折叠，把 "/tmp/../Users/x" 折成另一处位置。
func sessionFileGrantPath(raw string) (string, bool) {
	path := strings.TrimSpace(raw)
	if path == "" || !filepath.IsAbs(path) || strings.ContainsRune(path, 0) {
		return "", false
	}
	for _, part := range strings.Split(filepath.ToSlash(path), "/") {
		if part == ".." {
			return "", false
		}
	}
	path = filepath.Clean(path)
	if !agentFileReferenceHasPreviewExtension(path) {
		return "", false
	}
	return path, true
}

// lexicalRoots 返回临时目录的原始写法与 canonical 写法，用于登记阶段的廉价筛选。
func (s *sessionFileGrantStore) lexicalRoots() []string {
	var result []string
	for _, raw := range s.roots {
		value := strings.TrimSpace(raw)
		if value == "" || !filepath.IsAbs(value) {
			continue
		}
		result = append(result, filepath.Clean(value))
		if canonical, err := filepath.EvalSymlinks(value); err == nil {
			result = append(result, filepath.Clean(canonical))
		}
	}
	return result
}

// canonicalRootFor 返回包含 realPath（已解析符号链接）的临时目录 canonical 根。
func (s *sessionFileGrantStore) canonicalRootFor(realPath string) (string, bool) {
	for _, raw := range s.roots {
		value := strings.TrimSpace(raw)
		if value == "" || !filepath.IsAbs(value) {
			continue
		}
		canonical, err := filepath.EvalSymlinks(value)
		if err != nil {
			continue
		}
		canonical = filepath.Clean(canonical)
		if realPath != canonical && realPathWithin(canonical, realPath) {
			return canonical, true
		}
	}
	return "", false
}

func pathStrictlyWithinAny(roots []string, path string) bool {
	for _, root := range roots {
		if path != root && realPathWithin(root, path) {
			return true
		}
	}
	return false
}

func (s *sessionFileGrantStore) grant(paths []string) {
	if s == nil || len(paths) == 0 {
		return
	}
	// 先在锁外筛选、去重并封顶：一页历史或不分页的 thread/resume 可能带上成千上万条路径，
	// 一次最多登记 maxEntries 条，超出部分反正会被立即淘汰。
	roots := s.lexicalRoots()
	accepted := make([]string, 0, min(len(paths), max(s.maxEntries, 0)))
	seen := map[string]struct{}{}
	for _, raw := range paths {
		if s.maxEntries > 0 && len(accepted) >= s.maxEntries {
			break
		}
		path, ok := sessionFileGrantPath(raw)
		if !ok || !pathStrictlyWithinAny(roots, path) {
			continue
		}
		if _, duplicate := seen[path]; duplicate {
			continue
		}
		seen[path] = struct{}{}
		accepted = append(accepted, path)
	}
	if len(accepted) == 0 {
		return
	}
	now := s.now()
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneLocked(now)
	for _, path := range accepted {
		s.lastSeen[path] = now
	}
	s.enforceLimitLocked()
}

func (s *sessionFileGrantStore) granted(path string) bool {
	if s == nil {
		return false
	}
	now := s.now()
	s.mu.Lock()
	defer s.mu.Unlock()
	seen, ok := s.lastSeen[path]
	if !ok {
		return false
	}
	if s.ttl > 0 && now.Sub(seen) > s.ttl {
		delete(s.lastSeen, path)
		return false
	}
	return true
}

func (s *sessionFileGrantStore) pruneLocked(now time.Time) {
	if s.ttl <= 0 {
		return
	}
	for path, seen := range s.lastSeen {
		if now.Sub(seen) > s.ttl {
			delete(s.lastSeen, path)
		}
	}
}

// enforceLimitLocked 超出容量时一次排序淘汰最久未被再次提到的路径，开销为 O(n log n)，
// 不随超出条数逐条重扫整张表。
func (s *sessionFileGrantStore) enforceLimitLocked() {
	excess := len(s.lastSeen) - s.maxEntries
	if s.maxEntries <= 0 || excess <= 0 {
		return
	}
	type entry struct {
		path string
		seen time.Time
	}
	entries := make([]entry, 0, len(s.lastSeen))
	for path, seen := range s.lastSeen {
		entries = append(entries, entry{path: path, seen: seen})
	}
	sort.Slice(entries, func(i, j int) bool {
		if !entries[i].seen.Equal(entries[j].seen) {
			return entries[i].seen.Before(entries[j].seen)
		}
		return entries[i].path < entries[j].path
	})
	for _, oldest := range entries[:excess] {
		delete(s.lastSeen, oldest.path)
	}
}

// 带 item 的帧才可能有 AI 产出；再要求出现某个临时目录前缀，绝大多数历史页不必解码。
var agentFileReferenceItemMarkers = [][]byte{
	[]byte(`"agentMessage"`), []byte(`"imageView"`), []byte(`"imageGeneration"`), []byte(`"fileChange"`),
}

// observeAgentProducedFiles 由 gateway 在转发已授权 thread 的 history 响应或 item 通知时调用。
func (r *Router) observeAgentProducedFiles(payload []byte) {
	if r == nil || r.sessionFileGrants == nil || len(payload) == 0 {
		return
	}
	store := r.sessionFileGrants
	hasItem := false
	for _, marker := range agentFileReferenceItemMarkers {
		if bytes.Contains(payload, marker) {
			hasItem = true
			break
		}
	}
	if !hasItem {
		return
	}
	mentionsRoot := false
	for _, root := range store.lexicalRoots() {
		if bytes.Contains(payload, []byte(root+string(filepath.Separator))) {
			mentionsRoot = true
			break
		}
	}
	if !mentionsRoot {
		return
	}
	var root any
	if err := json.Unmarshal(payload, &root); err != nil {
		return
	}
	var paths []string
	collectAgentProducedFilePaths(root, func(path string) {
		paths = append(paths, path)
	})
	store.grant(paths)
}

// resolveSessionReferencedTemporaryFile 返回 (resolved, candidate, err)。candidate 表示路径被已授权
// 会话的 AI 提到过且位于临时目录：此时文件缺失保留 ENOENT，让客户端提示“文件已不存在”，
// 不误报为越界；其余不合规一律按越界处理。
func (r *Router) resolveSessionReferencedTemporaryFile(raw string) (fileReadResolvedPath, bool, error) {
	if r == nil || r.sessionFileGrants == nil {
		return fileReadResolvedPath{}, false, nil
	}
	store := r.sessionFileGrants
	path, ok := sessionFileGrantPath(raw)
	if !ok || !pathStrictlyWithinAny(store.lexicalRoots(), path) || !store.granted(path) {
		return fileReadResolvedPath{}, false, nil
	}
	// 最终文件不能是符号链接、硬链接、非普通文件或他人创建的文件。
	info, err := os.Lstat(path)
	if err != nil {
		return fileReadResolvedPath{}, true, err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || !fileOwnedByCurrentUserWithSingleLink(info) {
		return fileReadResolvedPath{}, true, errFilePathOutsideScope
	}
	realPath, err := filepath.EvalSymlinks(path)
	if err != nil {
		return fileReadResolvedPath{}, true, err
	}
	// 上级目录经符号链接跳出临时目录（例如指向 Home 下的私有目录）时拒绝。
	trustedRoot, ok := store.canonicalRootFor(realPath)
	if !ok {
		return fileReadResolvedPath{}, true, errFilePathOutsideScope
	}
	return fileReadResolvedPath{
		realPath:     realPath,
		verifiedFile: info,
		trustedRoot:  trustedRoot,
	}, true, nil
}

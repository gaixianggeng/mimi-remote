package projects

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

var idPattern = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

const maxPathMatchCacheEntries = 2048

type Project struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Path     string `json:"path"`
	RealPath string `json:"-"`
	Missing  bool   `json:"missing,omitempty"`
}

type Registry struct {
	mu                sync.RWMutex
	projects          map[string]Project
	list              []Project
	pathCandidates    []projectPathCandidate
	projectRefreshSeq map[string]uint64
	indexGen          uint64
	nextSeq           atomic.Uint64
	cacheMu           sync.Mutex
	cacheGen          uint64
	pathMatchCache    map[string]projectPathMatchCacheEntry
	pathMatchOrder    []string
}

type projectPathCandidate struct {
	project Project
	path    string
	depth   int
}

type projectPathMatchCacheEntry struct {
	project Project
	ok      bool
}

func NewRegistry(configs []config.ProjectConfig) (*Registry, error) {
	registry := &Registry{
		projects:          map[string]Project{},
		projectRefreshSeq: map[string]uint64{},
		pathMatchCache:    map[string]projectPathMatchCacheEntry{},
	}
	for _, item := range configs {
		project, err := normalize(item)
		if err != nil {
			return nil, err
		}
		if _, exists := registry.projects[project.ID]; exists {
			return nil, fmt.Errorf("项目 ID 重复：%s", project.ID)
		}
		registry.projects[project.ID] = project
		registry.list = append(registry.list, project)
	}
	sort.Slice(registry.list, func(i, j int) bool {
		return registry.list[i].Name < registry.list[j].Name
	})
	registry.pathCandidates = buildProjectPathCandidates(registry.list)
	return registry, nil
}

func normalize(item config.ProjectConfig) (Project, error) {
	if item.ID == "" {
		return Project{}, fmt.Errorf("项目 ID 不能为空：%s", item.Path)
	}
	if !idPattern.MatchString(item.ID) {
		return Project{}, fmt.Errorf("项目 ID 只能包含字母、数字、下划线和短横线：%s", item.ID)
	}
	if item.Name == "" {
		item.Name = item.ID
	}
	abs, err := filepath.Abs(item.Path)
	if err != nil {
		return Project{}, fmt.Errorf("解析项目路径失败：%w", err)
	}
	if _, lstatErr := os.Lstat(abs); lstatErr != nil {
		if errors.Is(lstatErr, os.ErrNotExist) {
			// 已登记目录被移动或删除时降级为只读缺失状态，不阻止整个网关启动（C14/C15）。
			// 写路径授权仍要求目录在磁盘上真实存在，仅只读历史回溯使用规范化后的缺失路径。
			canonicalMissing, ok := canonicalMissingProjectPath(abs)
			if !ok {
				return Project{}, fmt.Errorf("项目路径不可访问 %s：%w", abs, lstatErr)
			}
			return Project{ID: item.ID, Name: item.Name, Path: abs, RealPath: canonicalMissing, Missing: true}, nil
		}
		return Project{}, fmt.Errorf("项目路径不可访问 %s：%w", abs, lstatErr)
	}
	realPath, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return Project{}, fmt.Errorf("项目路径不可访问 %s：%w", abs, err)
	}
	stat, err := os.Stat(realPath)
	if err != nil {
		return Project{}, fmt.Errorf("读取项目路径失败 %s：%w", realPath, err)
	}
	if !stat.IsDir() {
		return Project{}, fmt.Errorf("项目路径不是目录：%s", realPath)
	}
	return Project{ID: item.ID, Name: item.Name, Path: abs, RealPath: realPath}, nil
}

// canonicalMissingProjectPath 仅在目标路径真实不存在时，沿不存在的尾段向上找到最近存在的祖先目录，
// 对该祖先执行 EvalSymlinks 并确认其为目录后再拼回缺失尾段；若中间遇到越界/悬空符号链接或权限错误则返回 false。
func canonicalMissingProjectPath(abs string) (string, bool) {
	cleaned := filepath.Clean(abs)
	if !filepath.IsAbs(cleaned) {
		return "", false
	}
	var tail []string
	cur := cleaned
	for {
		_, err := os.Lstat(cur)
		if err == nil {
			realAncestor, evalErr := filepath.EvalSymlinks(cur)
			if evalErr != nil {
				return "", false
			}
			info, statErr := os.Stat(realAncestor)
			if statErr != nil || !info.IsDir() {
				return "", false
			}
			parts := append([]string{realAncestor}, tail...)
			return filepath.Join(parts...), true
		}
		if !errors.Is(err, os.ErrNotExist) {
			return "", false
		}
		parent := filepath.Dir(cur)
		if parent == cur {
			return "", false
		}
		base := filepath.Base(cur)
		if base == "" || base == "." || base == ".." {
			return "", false
		}
		tail = append([]string{base}, tail...)
		cur = parent
	}
}

// onRefreshProjectAvailabilityForTest 仅用于单测断言纯内存路径未触发任何磁盘可用性探测。
var onRefreshProjectAvailabilityForTest func(Project)

// refreshProjectAvailability 实时核对已登记项目目录当前是否存在于磁盘（C14）：
// 目录在网关运行期间被移走或恢复后，`/api/projects` 与 `/api/app-server/config`
// 立即反映最新 `Missing` 状态，无需等待下一次网关重启。
func refreshProjectAvailability(project Project) Project {
	if onRefreshProjectAvailabilityForTest != nil {
		onRefreshProjectAvailabilityForTest(project)
	}
	if project.Path == "" {
		return project
	}
	if _, err := os.Lstat(project.Path); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			project.Missing = true
		}
		return project
	}
	realPath, err := filepath.EvalSymlinks(project.Path)
	if err != nil {
		project.Missing = true
		return project
	}
	info, err := os.Stat(realPath)
	if err != nil || !info.IsDir() {
		project.Missing = true
		return project
	}
	project.Missing = false
	project.RealPath = realPath
	return project
}

func (r *Registry) List() []Project {
	obsSeq := r.nextSeq.Add(1)
	base := r.ListCached()
	out := make([]Project, len(base))
	for i, project := range base {
		out[i] = refreshProjectAvailability(project)
	}
	r.applyRefreshedSnapshot(out, obsSeq)
	return out
}

func (r *Registry) Get(id string) (Project, bool) {
	obsSeq := r.nextSeq.Add(1)
	project, ok := r.GetCached(id)
	if !ok {
		return Project{}, false
	}
	refreshed := refreshProjectAvailability(project)
	r.applyRefreshedProject(refreshed, obsSeq)
	return refreshed, true
}

func (r *Registry) applyRefreshedSnapshot(updated []Project, obsSeq uint64) {
	if r == nil || len(updated) == 0 {
		return
	}
	r.mu.Lock()
	if r.projectRefreshSeq == nil {
		r.projectRefreshSeq = map[string]uint64{}
	}
	changed := false
	for _, next := range updated {
		prev, ok := r.projects[next.ID]
		if !ok {
			continue
		}
		if obsSeq < r.projectRefreshSeq[next.ID] {
			continue
		}
		r.projectRefreshSeq[next.ID] = obsSeq
		if prev.RealPath != next.RealPath || prev.Missing != next.Missing {
			changed = true
		}
		r.projects[next.ID] = next
	}
	for i, prev := range r.list {
		if next, ok := r.projects[prev.ID]; ok {
			r.list[i] = next
		}
	}
	if changed {
		r.indexGen++
		r.pathCandidates = buildProjectPathCandidates(r.list)
		r.invalidatePathMatchCacheLocked(r.indexGen)
	}
	r.mu.Unlock()
}

func (r *Registry) applyRefreshedProject(next Project, obsSeq uint64) {
	if r == nil || next.ID == "" {
		return
	}
	r.mu.Lock()
	if r.projectRefreshSeq == nil {
		r.projectRefreshSeq = map[string]uint64{}
	}
	if prev, ok := r.projects[next.ID]; ok && obsSeq >= r.projectRefreshSeq[next.ID] {
		r.projectRefreshSeq[next.ID] = obsSeq
		changed := prev.RealPath != next.RealPath || prev.Missing != next.Missing
		r.projects[next.ID] = next
		for i := range r.list {
			if r.list[i].ID == next.ID {
				r.list[i] = next
				break
			}
		}
		if changed {
			r.indexGen++
			r.pathCandidates = buildProjectPathCandidates(r.list)
			r.invalidatePathMatchCacheLocked(r.indexGen)
		}
	}
	r.mu.Unlock()
}

// invalidatePathMatchCacheLocked 要求调用方已持有 r.mu 写锁（锁序严格为 r.mu -> r.cacheMu）。
func (r *Registry) invalidatePathMatchCacheLocked(newGen uint64) {
	r.cacheMu.Lock()
	r.cacheGen = newGen
	clear(r.pathMatchCache)
	r.pathMatchOrder = r.pathMatchOrder[:0]
	r.cacheMu.Unlock()
}

// GetCached 纯内存按 ID 读取已登记项目，不触发 refreshProjectAvailability、
// os.Lstat / os.Stat 或 filepath.EvalSymlinks。
func (r *Registry) GetCached(id string) (Project, bool) {
	if r == nil {
		return Project{}, false
	}
	r.mu.RLock()
	project, ok := r.projects[id]
	r.mu.RUnlock()
	return project, ok
}

// ListCached 纯内存返回已登记项目列表拷贝，不触碰文件系统。
func (r *Registry) ListCached() []Project {
	if r == nil {
		return nil
	}
	r.mu.RLock()
	out := make([]Project, len(r.list))
	copy(out, r.list)
	r.mu.RUnlock()
	return out
}

// FindByCanonicalPathInMemory 对已规范化的绝对路径执行 100% 纯内存项目匹配：
// 零磁盘 I/O（不调用 EvalSymlinks / Stat / Abs），也不写入或淘汰共享 pathMatchCache。
func (r *Registry) FindByCanonicalPathInMemory(canonicalPath string) (Project, bool) {
	if r == nil {
		return Project{}, false
	}
	normalized, ok := pathForProjectMatch(canonicalPath)
	if !ok {
		return Project{}, false
	}
	clean := filepath.Clean(normalized)
	if clean == "" || clean == "." || !filepath.IsAbs(clean) {
		return Project{}, false
	}
	return r.findByCleanPath(clean)
}

// MatchCanonicalPathInList 在预先刷新好的项目快照中按规范路径执行最长前缀匹配，
// 复用与 FindByPath 一致的 Windows 扩展长度路径归一化（\\?\C:\...），零缓存写入。
func MatchCanonicalPathInList(list []Project, canonicalPath string) (Project, bool) {
	if len(list) == 0 {
		return Project{}, false
	}
	normalized, ok := pathForProjectMatch(canonicalPath)
	if !ok {
		return Project{}, false
	}
	clean := filepath.Clean(normalized)
	if clean == "" || clean == "." || !filepath.IsAbs(clean) {
		return Project{}, false
	}
	var best Project
	bestLen := -1
	for _, project := range list {
		if project.Missing {
			continue
		}
		for _, candidate := range []string{project.RealPath, project.Path} {
			if candidate == "" {
				continue
			}
			normRoot, rootOK := pathForProjectMatch(candidate)
			if !rootOK {
				continue
			}
			cleanRoot := filepath.Clean(normRoot)
			rel, err := filepath.Rel(cleanRoot, clean)
			if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
				continue
			}
			if len(cleanRoot) > bestLen {
				best = project
				bestLen = len(cleanRoot)
			}
		}
	}
	if bestLen < 0 {
		return Project{}, false
	}
	return best, true
}

// FindByPathVerifyingMatch 使用已刷新规范索引匹配路径，并在命中时按最深到最浅顺序
// 仅复核匹配该路径的候选项目（跳过其他无关项目）；若更具体的嵌套项目已失效或改指，
// 继续向下核验外层父项目，确保健康父工作区不被误拒。
func (r *Registry) FindByPathVerifyingMatch(path string) (Project, bool) {
	if r == nil {
		return Project{}, false
	}
	normalized, ok := pathForProjectMatch(path)
	if !ok {
		return Project{}, false
	}
	absPath, err := filepath.Abs(normalized)
	if err != nil {
		return Project{}, false
	}
	realPath, err := filepath.EvalSymlinks(absPath)
	if err != nil {
		realPath = absPath
	}
	cleanReal := filepath.Clean(realPath)
	cleanAbs := filepath.Clean(absPath)

	matchedCandidates := r.matchingCandidatesByCleanPath(cleanReal, cleanAbs)
	for _, cand := range matchedCandidates {
		obsSeq := r.nextSeq.Add(1)
		live := refreshProjectAvailability(cand)
		r.applyRefreshedProject(live, obsSeq)
		if live.Missing {
			continue
		}
		if project, ok := MatchCanonicalPathInList([]Project{live}, cleanReal); ok {
			return project, true
		}
		if cleanAbs != cleanReal {
			if project, ok := MatchCanonicalPathInList([]Project{live}, cleanAbs); ok {
				return project, true
			}
		}
	}
	return Project{}, false
}

func (r *Registry) matchingCandidatesByCleanPath(cleanReal string, cleanAbs string) []Project {
	r.mu.RLock()
	candidates := r.pathCandidates
	r.mu.RUnlock()

	var matched []Project
	seen := map[string]struct{}{}
	collectFor := func(target string) {
		if target == "" || target == "." {
			return
		}
		for _, candidate := range candidates {
			if _, dup := seen[candidate.project.ID]; dup {
				continue
			}
			rel, err := filepath.Rel(candidate.path, target)
			if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
				continue
			}
			seen[candidate.project.ID] = struct{}{}
			matched = append(matched, candidate.project)
		}
	}
	collectFor(cleanReal)
	if cleanAbs != cleanReal {
		collectFor(cleanAbs)
	}
	return matched
}

func (r *Registry) FindByPath(path string) (Project, bool) {
	path, ok := pathForProjectMatch(path)
	if !ok {
		return Project{}, false
	}
	cacheKey := ""
	absPath, err := filepath.Abs(path)
	if err == nil {
		cacheKey = filepath.Clean(absPath)
		if project, ok, hit := r.cachedPathMatch(cacheKey, r.currentIndexGen()); hit {
			return project, ok
		}
		if project, ok, gen := r.findByCleanPathWithGen(cacheKey); ok {
			// Codex history 里的 cwd 通常是项目绝对路径或子路径。直接字符串命中时立即按当前索引代次缓存，
			// 后续侧栏刷新不再重复遍历候选项目；若并发刷新推进了索引代次则自动放弃回填。
			r.storePathMatch(cacheKey, gen, project, true)
			return project, true
		}
	}

	realPath, err := filepath.EvalSymlinks(path)
	if err != nil {
		realPath = absPath
	}
	cleanRealPath := filepath.Clean(realPath)
	project, ok, gen := r.findByCleanPathWithGen(cleanRealPath)
	if cacheKey != "" {
		r.storePathMatch(cacheKey, gen, project, ok)
	}
	if cleanRealPath != "" && cleanRealPath != "." && cleanRealPath != cacheKey {
		r.storePathMatch(cleanRealPath, gen, project, ok)
	}
	return project, ok
}

// pathForProjectMatch accepts the Windows extended-length spelling that Codex
// persists for local drive paths while keeping device and network namespaces
// outside the project allowlist. filepath.Rel does not consider
// `\\?\C:\dir` equivalent to `C:\dir`, even though both names address the
// same local directory on Windows.
func pathForProjectMatch(path string) (string, bool) {
	if runtime.GOOS != "windows" {
		return path, true
	}

	clean := filepath.Clean(path)
	const extendedPrefix = `\\?\`
	if strings.HasPrefix(clean, extendedPrefix) {
		localPath := strings.TrimPrefix(clean, extendedPrefix)
		volume := filepath.VolumeName(localPath)
		if len(volume) != 2 || volume[1] != ':' ||
			!((volume[0] >= 'A' && volume[0] <= 'Z') ||
				(volume[0] >= 'a' && volume[0] <= 'z')) ||
			len(localPath) <= len(volume) || !os.IsPathSeparator(localPath[len(volume)]) {
			return "", false
		}
		return filepath.Clean(localPath), true
	}

	// Do not let Win32 device or NT object-manager spellings pass through Abs
	// and accidentally compare equal to an authorized local project.
	if strings.HasPrefix(clean, `\\.\`) || strings.HasPrefix(clean, `\??\`) {
		return "", false
	}
	return clean, true
}

func (r *Registry) currentIndexGen() uint64 {
	r.mu.RLock()
	gen := r.indexGen
	r.mu.RUnlock()
	return gen
}

func (r *Registry) findByCleanPath(cleanPath string) (Project, bool) {
	project, ok, _ := r.findByCleanPathWithGen(cleanPath)
	return project, ok
}

func (r *Registry) findByCleanPathWithGen(cleanPath string) (Project, bool, uint64) {
	r.mu.RLock()
	candidates := r.pathCandidates
	gen := r.indexGen
	r.mu.RUnlock()
	for _, candidate := range candidates {
		rel, err := filepath.Rel(candidate.path, cleanPath)
		if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
			continue
		}
		return candidate.project, true, gen
	}
	return Project{}, false, gen
}

func (r *Registry) cachedPathMatch(cleanPath string, gen uint64) (Project, bool, bool) {
	if cleanPath == "" || cleanPath == "." {
		return Project{}, false, false
	}
	r.cacheMu.Lock()
	defer r.cacheMu.Unlock()

	if gen != r.cacheGen {
		return Project{}, false, false
	}
	entry, hit := r.pathMatchCache[cleanPath]
	if !hit {
		return Project{}, false, false
	}
	r.pathMatchOrder = touchPathMatchCacheKey(r.pathMatchOrder, cleanPath)
	return entry.project, entry.ok, true
}

func (r *Registry) storePathMatch(cleanPath string, gen uint64, project Project, ok bool) {
	if cleanPath == "" || cleanPath == "." {
		return
	}
	r.cacheMu.Lock()
	defer r.cacheMu.Unlock()

	if gen != r.cacheGen {
		return
	}
	r.pathMatchCache[cleanPath] = projectPathMatchCacheEntry{project: project, ok: ok}
	r.pathMatchOrder = touchPathMatchCacheKey(r.pathMatchOrder, cleanPath)
	for len(r.pathMatchCache) > maxPathMatchCacheEntries && len(r.pathMatchOrder) > 0 {
		oldest := r.pathMatchOrder[0]
		r.pathMatchOrder = r.pathMatchOrder[1:]
		delete(r.pathMatchCache, oldest)
	}
}

func touchPathMatchCacheKey(order []string, key string) []string {
	writeIndex := 0
	for _, value := range order {
		if value == key {
			continue
		}
		order[writeIndex] = value
		writeIndex++
	}
	order = order[:writeIndex]
	return append(order, key)
}

func buildProjectPathCandidates(projects []Project) []projectPathCandidate {
	candidates := make([]projectPathCandidate, 0, len(projects)*2)
	for _, project := range projects {
		candidates = appendProjectPathCandidate(candidates, project, project.RealPath)
		if project.Path != "" && project.Path != project.RealPath {
			candidates = appendProjectPathCandidate(candidates, project, project.Path)
		}
	}
	// Codex 历史里的 cwd 经常是项目子目录；候选路径预先按深度排序，
	// FindByPath 就可以直接返回第一个匹配项，避免每条历史都重新 Clean/Split。
	sort.SliceStable(candidates, func(i, j int) bool {
		return candidates[i].depth > candidates[j].depth
	})
	return candidates
}

func appendProjectPathCandidate(candidates []projectPathCandidate, project Project, path string) []projectPathCandidate {
	if normalized, ok := pathForProjectMatch(path); ok {
		path = normalized
	}
	clean := filepath.Clean(path)
	return append(candidates, projectPathCandidate{
		project: project,
		path:    clean,
		depth:   pathDepth(clean),
	})
}

func pathDepth(path string) int {
	if path == string(os.PathSeparator) {
		return 0
	}
	return len(strings.Split(strings.Trim(path, string(os.PathSeparator)), string(os.PathSeparator)))
}

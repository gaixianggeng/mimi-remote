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
	projects       map[string]Project
	list           []Project
	pathCandidates []projectPathCandidate
	cacheMu        sync.Mutex
	pathMatchCache map[string]projectPathMatchCacheEntry
	pathMatchOrder []string
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
		projects:       map[string]Project{},
		pathMatchCache: map[string]projectPathMatchCacheEntry{},
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

func (r *Registry) List() []Project {
	out := make([]Project, len(r.list))
	copy(out, r.list)
	return out
}

func (r *Registry) Get(id string) (Project, bool) {
	project, ok := r.projects[id]
	return project, ok
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
		if project, ok, hit := r.cachedPathMatch(cacheKey); hit {
			return project, ok
		}
		if project, ok := r.findByCleanPath(cacheKey); ok {
			// Codex history 里的 cwd 通常是项目绝对路径或子路径。直接字符串命中时立即缓存，
			// 后续侧栏刷新不再重复遍历候选项目。
			r.storePathMatch(cacheKey, project, true)
			return project, true
		}
	}

	realPath, err := filepath.EvalSymlinks(path)
	if err != nil {
		realPath = absPath
	}
	cleanRealPath := filepath.Clean(realPath)
	project, ok := r.findByCleanPath(cleanRealPath)
	if cacheKey != "" {
		// Registry 创建后项目集合不会变；把最终结果按原始绝对路径缓存起来，
		// 包含“未匹配”结果，避免频繁轮询时对无关 cwd 做重复 EvalSymlinks/Rel。
		r.storePathMatch(cacheKey, project, ok)
	}
	if cleanRealPath != "" && cleanRealPath != "." && cleanRealPath != cacheKey {
		r.storePathMatch(cleanRealPath, project, ok)
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

func (r *Registry) findByCleanPath(cleanPath string) (Project, bool) {
	for _, candidate := range r.pathCandidates {
		rel, err := filepath.Rel(candidate.path, cleanPath)
		if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
			continue
		}
		return candidate.project, true
	}
	return Project{}, false
}

func (r *Registry) cachedPathMatch(cleanPath string) (Project, bool, bool) {
	if cleanPath == "" || cleanPath == "." {
		return Project{}, false, false
	}
	r.cacheMu.Lock()
	defer r.cacheMu.Unlock()

	entry, hit := r.pathMatchCache[cleanPath]
	if !hit {
		return Project{}, false, false
	}
	r.pathMatchOrder = touchPathMatchCacheKey(r.pathMatchOrder, cleanPath)
	return entry.project, entry.ok, true
}

func (r *Registry) storePathMatch(cleanPath string, project Project, ok bool) {
	if cleanPath == "" || cleanPath == "." {
		return
	}
	r.cacheMu.Lock()
	defer r.cacheMu.Unlock()

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

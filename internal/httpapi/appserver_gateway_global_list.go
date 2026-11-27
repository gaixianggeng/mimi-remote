package httpapi

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

// appServerGatewayGlobalListGitWait 是全局发现响应等待 Git 归属判定的上限（#789）。
// 响应策略在每条连接唯一的读循环里同步执行，等待越久，同连接后面的作用域列表、
// 历史读取就排得越久。缓存命中时不需要等待；冷缓存或 Git 变慢时最多等这么久，
// 还没结论的目录让本页返回“重取本页”的 cursor，判定在后台继续并写入缓存。
var appServerGatewayGlobalListGitWait = 300 * time.Millisecond

func (p *appServerGatewayPolicy) resolveGlobalListCursor(params map[string]any) error {
	raw, exists := params["cursor"]
	if !exists || raw == nil {
		return nil
	}
	token, ok := raw.(string)
	token = strings.TrimSpace(token)
	if !ok || token == "" {
		return fmt.Errorf("thread/list.cursor 必须是非空字符串")
	}
	p.mu.Lock()
	upstream, found := p.globalListCursors[token]
	p.mu.Unlock()
	if !found {
		return fmt.Errorf("thread/list.cursor 已失效或不属于当前授权连接")
	}
	if strings.TrimSpace(upstream) == "" {
		// 重试首页的 cursor（见 storeGlobalListRetryCursor）：上游首页本来就不带 cursor。
		delete(params, "cursor")
		return nil
	}
	params["cursor"] = upstream
	return nil
}

func (p *appServerGatewayPolicy) storeGlobalListCursor(upstream string) (string, error) {
	upstream = strings.TrimSpace(upstream)
	if upstream == "" {
		return "", nil
	}
	return p.storeGlobalListCursorToken(upstream)
}

// storeGlobalListRetryCursor 返回一个重新请求同一页的 cursor；upstream 为空表示首页。
// 授权过滤没能判定完本页时用它代替上游的 nextCursor：客户端不会因此认为遍历已经
// 走完，也不会跳过本页未判定的条目（#789）。
func (p *appServerGatewayPolicy) storeGlobalListRetryCursor(upstream string) (string, error) {
	return p.storeGlobalListCursorToken(strings.TrimSpace(upstream))
}

func (p *appServerGatewayPolicy) storeGlobalListCursorToken(upstream string) (string, error) {
	raw := make([]byte, 18)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("生成 thread/list 安全 cursor 失败")
	}
	token := "mimi_" + base64.RawURLEncoding.EncodeToString(raw)
	p.mu.Lock()
	if p.globalListCursors == nil || len(p.globalListCursors) >= appServerGatewayGlobalCursorMax {
		// cursor 只在当前 gateway 连接内有效。容量到顶时整体换代比逐项 LRU 更简单，
		// 旧页继续请求会明确失败，不会退回接受 upstream 原始 cursor。
		p.globalListCursors = map[string]string{}
	}
	p.globalListCursors[token] = upstream
	p.mu.Unlock()
	return token, nil
}

// resolveGlobalListBrowseProjects 判定 browse-root 目录各自归属哪个已登记项目（归属不到
// 时为空 Project）。unsettled 里的目录在等待预算内没有结论：本页对它们既不放行，
// 也不当作不存在。目录都不在 Git 仓库里时不扫描已登记项目。
func (p *appServerGatewayPolicy) resolveGlobalListBrowseProjects(ctx context.Context, paths []string, refreshedProjects []projects.Project) (map[string]projects.Project, map[string]struct{}) {
	projectByPath := map[string]projects.Project{}
	unsettled := map[string]struct{}{}
	if len(paths) == 0 {
		return projectByPath, unsettled
	}
	results := p.router.gatewayGitCommonDirs(ctx, paths)
	var projectByCommonDir map[string]projects.Project
	projectsSettled := true
	for _, result := range results {
		// 未判定的目录之后仍可能属于某个仓库：也要把已登记项目的判定一并发起，
		// 预算用完时它们在后台继续，客户端重取本页时两边都已命中缓存。
		if !result.settled || result.ok {
			projectByCommonDir, projectsSettled = p.authorizedProjectsByGitCommonDirWithSnapshot(ctx, refreshedProjects)
			break
		}
	}
	for index, path := range paths {
		result := results[index]
		switch {
		case !result.settled:
			unsettled[path] = struct{}{}
		case !result.ok:
			projectByPath[path] = projects.Project{}
		case !projectsSettled:
			// 同仓项目没判定全时，按 common-dir 选出的主项目可能不是全量判定下的那个，
			// 查不到也不能当作“仓库未授权”。
			unsettled[path] = struct{}{}
		default:
			projectByPath[path] = projectByCommonDir[result.commonDir]
		}
	}
	return projectByPath, unsettled
}

// authorizedProjectsByGitCommonDir 按 Git common-dir 归并已登记项目。settled=false 表示
// 有项目的 Git 没给出结论：此时查不到归属不能当作“仓库未授权”的证据。
func (p *appServerGatewayPolicy) authorizedProjectsByGitCommonDir(ctx context.Context) (map[string]projects.Project, bool) {
	return p.authorizedProjectsByGitCommonDirWithSnapshot(ctx, nil)
}

func (p *appServerGatewayPolicy) authorizedProjectsByGitCommonDirWithSnapshot(ctx context.Context, refreshedProjects []projects.Project) (map[string]projects.Project, bool) {
	grouped := map[string][]projects.Project{}
	out := map[string]projects.Project{}
	registered := refreshedProjects
	if registered == nil && p.router != nil && p.router.projects != nil {
		// 阶段 A 锁外解析 Git 归属时刷新已登记项目的规范路径，避免配置符号链接改指后仍归属到旧仓库。
		registered = p.router.projects.List()
	}
	paths := make([]string, 0, len(registered))
	for _, project := range registered {
		paths = append(paths, project.RealPath)
	}
	settled := true
	for index, result := range p.router.gatewayGitCommonDirs(ctx, paths) {
		if !result.settled {
			settled = false
		}
		if !result.ok {
			continue
		}
		grouped[result.commonDir] = append(grouped[result.commonDir], registered[index])
	}
	for commonDir, candidates := range grouped {
		if project, ok := selectAuthorizedProjectForGitCommonDir(commonDir, candidates); ok {
			out[commonDir] = project
		}
	}
	return out, settled
}

func selectAuthorizedProjectForGitCommonDir(commonDir string, candidates []projects.Project) (projects.Project, bool) {
	if len(candidates) == 1 {
		return candidates[0], true
	}

	var primary projects.Project
	primaryCount := 0
	for _, project := range candidates {
		// linked worktree 的 .git 是指向 common-dir/worktrees/* 的文件；只有普通
		// 主工作树的 .git 目录（或其目录 symlink）会解析到仓库 common-dir。
		// 多 Project 共仓时据此稳定归属到唯一主项目，缺失或重复主项目仍 fail-closed。
		gitMarker := filepath.Join(project.RealPath, ".git")
		info, err := os.Stat(gitMarker)
		if err != nil || !info.IsDir() {
			continue
		}
		realGitMarker, err := filepath.EvalSymlinks(gitMarker)
		if err != nil || filepath.Clean(realGitMarker) != filepath.Clean(commonDir) {
			continue
		}
		primary = project
		primaryCount++
	}
	if primaryCount != 1 {
		return projects.Project{}, false
	}
	return primary, true
}

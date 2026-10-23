package httpapi

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
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

func (p *appServerGatewayPolicy) sanitizeGlobalThreadListResponse(
	payload []byte,
	pending appServerGatewayPendingThreadRequest,
) ([]byte, []appServerGatewayAllowedThread, error) {
	var response map[string]json.RawMessage
	if err := json.Unmarshal(payload, &response); err != nil {
		return nil, nil, fmt.Errorf("thread/list response 无效")
	}
	var resultFields map[string]json.RawMessage
	if raw := response["result"]; len(raw) == 0 || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) || json.Unmarshal(raw, &resultFields) != nil {
		return nil, nil, fmt.Errorf("thread/list response.result 必须是对象")
	}
	dataRaw, ok := resultFields["data"]
	if !ok || bytes.Equal(bytes.TrimSpace(dataRaw), []byte("null")) {
		return nil, nil, fmt.Errorf("thread/list response.data 必须是数组")
	}
	var rawItems []json.RawMessage
	if err := json.Unmarshal(dataRaw, &rawItems); err != nil {
		return nil, nil, fmt.Errorf("thread/list response.data 必须是数组")
	}

	limit := int64(appServerGatewayThreadListMaxLimit)
	if pending.responseLimitSet {
		limit = pending.responseLimit
	}
	if limit <= 0 || limit > appServerGatewayThreadListMaxLimit {
		limit = appServerGatewayThreadListMaxLimit
	}
	// 先收集需要 Git 归属判定的 browse-root 目录，统一并行判定，再逐条裁剪。
	type globalListCandidate struct {
		itemFields map[string]json.RawMessage
		thread     appServerGatewayThreadWire
		threadID   string
		scope      gatewayScope
	}
	candidates := make([]globalListCandidate, 0, len(rawItems))
	var gitPaths []string
	seenGitPaths := map[string]struct{}{}
	for _, rawItem := range rawItems {
		var itemFields map[string]json.RawMessage
		var thread appServerGatewayThreadWire
		if json.Unmarshal(rawItem, &itemFields) != nil || json.Unmarshal(rawItem, &thread) != nil {
			continue
		}
		threadIDRaw := firstNonEmptyRaw(thread.ID, thread.ThreadID, thread.SessionID)
		cwdRaw := firstNonEmptyRaw(thread.CWD, thread.Path)
		threadID := strings.TrimSpace(threadIDRaw)
		cwd := strings.TrimSpace(cwdRaw)
		if threadID == "" || threadID != threadIDRaw || cwd == "" || cwd != cwdRaw || !filepath.IsAbs(cwd) {
			continue
		}
		scope, ok := p.router.gatewayScopeForPath(cwd)
		if !ok {
			continue
		}
		info, err := os.Stat(scope.realPath)
		if err != nil || !info.IsDir() {
			continue
		}
		if strings.TrimSpace(scope.project.ID) == "" && scope.browse {
			if _, seen := seenGitPaths[scope.realPath]; !seen {
				seenGitPaths[scope.realPath] = struct{}{}
				gitPaths = append(gitPaths, scope.realPath)
			}
		}
		candidates = append(candidates, globalListCandidate{itemFields: itemFields, thread: thread, threadID: threadID, scope: scope})
	}
	ctx, cancel := context.WithTimeout(context.Background(), appServerGatewayGlobalListGitWait)
	defer cancel()
	projectByPath, unsettledPaths := p.resolveGlobalListBrowseProjects(ctx, gitPaths)

	// incomplete 表示本页有条目在等待预算内没能判定归属。这些条目既不能放行，
	// 也不能当作“已不存在”，所以本页不能推进 cursor。
	incomplete := false
	safeItems := make([]map[string]any, 0, min(len(candidates), int(limit)))
	allowedThreads := make([]appServerGatewayAllowedThread, 0, cap(safeItems))
	for _, candidate := range candidates {
		if int64(len(safeItems)) >= limit {
			break
		}
		itemFields, thread, threadID, scope := candidate.itemFields, candidate.thread, candidate.threadID, candidate.scope
		project := scope.project
		if strings.TrimSpace(project.ID) == "" && scope.browse {
			if _, unsettled := unsettledPaths[scope.realPath]; unsettled {
				incomplete = true
				continue
			}
			project = projectByPath[scope.realPath]
		}
		if strings.TrimSpace(project.ID) == "" {
			continue
		}

		// 外部 browse-root Worktree 和所有显式 parent 子会话都只有“可读发现”资格。
		// 上游即使声明 canAcceptDirectInput=true，也不能越过 Phase 1 父会话管理边界。
		forceReadOnly := scope.browse || strings.TrimSpace(thread.ParentThreadID) != ""
		canAccept := false
		directInputKnown := forceReadOnly || thread.CanAcceptDirectInput != nil
		if thread.CanAcceptDirectInput != nil && !forceReadOnly {
			canAccept = *thread.CanAcceptDirectInput
		}

		safeThread := copyGatewayRawFields(itemFields,
			"id", "sessionId", "threadId", "parentThreadId", "cwd", "path",
			"name", "preview", "status", "modelProvider", "source", "threadSource",
			"agentNickname", "agentRole", "gitInfo", "createdAt", "updatedAt", "recencyAt",
			"canAcceptDirectInput",
			// Claude bridge 在会话被本机其他 Claude 进程持有时附带的持有方摘要
			// （entrypoint/kind/status/pid），只用于展示"正在 Mac 上运行"，不参与授权。
			"claudeOwner",
			// Claude 桌面版"主会话派生会话"的父会话 ID，只用于列表分组展示。
			// 它不是 parentThreadId：派生会话是完整会话，不因此变成只读。
			"spawnedFromThreadId",
		)
		if forceReadOnly {
			safeThread["canAcceptDirectInput"] = false
		}
		safeThread["mimiRemote"] = map[string]any{
			"projectId":   project.ID,
			"projectName": project.Name,
			"projectPath": project.Path,
			"discovery":   "global",
			"readOnly":    forceReadOnly,
		}
		safeItems = append(safeItems, safeThread)
		allowedThreads = append(allowedThreads, appServerGatewayAllowedThread{
			id:                   threadID,
			runtimeID:            normalizeAppServerRuntimeID(p.runtimeID),
			cwd:                  scope.realPath,
			scopeID:              scope.id,
			canAcceptDirectInput: canAccept,
			directInputKnown:     directInputKnown,
			readOnly:             forceReadOnly,
		})
	}

	safeResult := map[string]any{"data": safeItems}
	if incomplete {
		cursor, err := p.storeGlobalListRetryCursor(pending.upstreamCursor)
		if err != nil {
			return nil, nil, err
		}
		log.Printf("app-server gateway global thread/list incomplete runtime=%s returned=%d upstream=%d; client will retry the same page", p.runtimeID, len(safeItems), len(rawItems))
		safeResult["nextCursor"] = cursor
	} else if rawCursor, exists := resultFields["nextCursor"]; exists && !bytes.Equal(bytes.TrimSpace(rawCursor), []byte("null")) {
		var upstreamCursor string
		if json.Unmarshal(rawCursor, &upstreamCursor) == nil && strings.TrimSpace(upstreamCursor) != "" {
			cursor, err := p.storeGlobalListCursor(upstreamCursor)
			if err != nil {
				return nil, nil, err
			}
			safeResult["nextCursor"] = cursor
		}
	} else if exists {
		safeResult["nextCursor"] = nil
	}
	safeResponse := map[string]any{
		"jsonrpc": "2.0",
		"id":      response["id"],
		"result":  safeResult,
	}
	rewritten, err := json.Marshal(safeResponse)
	if err != nil {
		return nil, nil, fmt.Errorf("重写 thread/list response 失败：%w", err)
	}
	return rewritten, allowedThreads, nil
}

// resolveGlobalListBrowseProjects 判定 browse-root 目录各自归属哪个已登记项目（归属不到
// 时为空 Project）。unsettled 里的目录在等待预算内没有结论：本页对它们既不放行，
// 也不当作不存在。目录都不在 Git 仓库里时不扫描已登记项目。
func (p *appServerGatewayPolicy) resolveGlobalListBrowseProjects(ctx context.Context, paths []string) (map[string]projects.Project, map[string]struct{}) {
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
			projectByCommonDir, projectsSettled = p.authorizedProjectsByGitCommonDir(ctx)
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
	grouped := map[string][]projects.Project{}
	out := map[string]projects.Project{}
	registered := p.router.projects.List()
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

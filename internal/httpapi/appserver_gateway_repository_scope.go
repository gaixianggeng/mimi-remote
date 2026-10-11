package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"time"
)

// dropUnauthorizedScopedThreads 让按目录查询的列表只包含本连接能打开的会话。
// 全局发现早已按授权结果重写响应；按仓库查询现在也可能带回同仓其他 worktree 的
// 会话，其中工作目录已删除或不在授权范围的条目点开必然失败，不应出现在列表里。
// 其余字段（分页游标、条目内容）原样保留。
func dropUnauthorizedScopedThreads(payload []byte, allowed []appServerGatewayAllowedThread) []byte {
	var response map[string]json.RawMessage
	if json.Unmarshal(payload, &response) != nil {
		return payload
	}
	var result map[string]json.RawMessage
	if raw := response["result"]; len(raw) == 0 || json.Unmarshal(raw, &result) != nil {
		return payload
	}
	var items []json.RawMessage
	if raw := result["data"]; len(raw) == 0 || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) || json.Unmarshal(raw, &items) != nil {
		return payload
	}
	allowedIDs := make(map[string]struct{}, len(allowed))
	for _, thread := range allowed {
		allowedIDs[thread.id] = struct{}{}
	}
	kept := make([]json.RawMessage, 0, len(items))
	for _, item := range items {
		var thread appServerGatewayThreadWire
		if json.Unmarshal(item, &thread) != nil {
			continue
		}
		if _, ok := allowedIDs[strings.TrimSpace(firstNonEmpty(thread.ID, thread.ThreadID, thread.SessionID))]; ok {
			kept = append(kept, item)
		}
	}
	if len(kept) == len(items) {
		return payload
	}
	data, err := json.Marshal(kept)
	if err != nil {
		return payload
	}
	result["data"] = data
	resultRaw, err := json.Marshal(result)
	if err != nil {
		return payload
	}
	response["result"] = resultRaw
	rewritten, err := json.Marshal(response)
	if err != nil {
		return payload
	}
	return rewritten
}

// gatewaySameRepository 判断按目录查询的 thread/list 结果是否与查询目录属于同一
// Git 仓库。Claude 适配器按 Claude Code `listSessions({ dir })` 的语义返回同仓所有
// worktree 的会话，其中仓库外的兄弟 worktree 会落在别的授权作用域里；只要 git
// common-dir 相同，就按会话自己的作用域授权，避免列表里出现点不开的会话。
//
// 每次响应只解析一次查询目录，并缓存各会话目录的结果；只有作用域不一致的条目
// 才会触发 git 调用，Codex 按精确 cwd 返回的列表不会走到这里。
type gatewaySameRepository struct {
	requestCWD string
	ctx        context.Context
	cancel     context.CancelFunc
	resolved   bool
	commonDir  string
	byPath     map[string]string
}

func newGatewaySameRepository(requestCWD string) *gatewaySameRepository {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	return &gatewaySameRepository{requestCWD: requestCWD, ctx: ctx, cancel: cancel, byPath: map[string]string{}}
}

func (s *gatewaySameRepository) matches(realPath string) bool {
	if !s.resolved {
		s.resolved = true
		if commonDir, ok := gitCommonDirectory(s.ctx, s.requestCWD); ok {
			s.commonDir = commonDir
		}
	}
	if s.commonDir == "" {
		return false
	}
	commonDir, cached := s.byPath[realPath]
	if !cached {
		commonDir, _ = gitCommonDirectory(s.ctx, realPath)
		s.byPath[realPath] = commonDir
	}
	return commonDir == s.commonDir
}

func (s *gatewaySameRepository) close() {
	if s != nil {
		s.cancel()
	}
}

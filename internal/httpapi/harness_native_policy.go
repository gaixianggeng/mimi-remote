package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

// 本文件是 /api/harness/rpc 的授权与裁剪策略：中继只放行只读方法，并且在触达
// Harness 之前就把"这次调用到底能看见哪些会话"定下来。
//
// 与 internal/httpapi 里 DeepSeek gateway 的分工：gateway 把 Harness 事件翻译成
// app-server 协议给旧客户端用；中继不翻译，它把原生结果按原字段下发，只做授权。
// 因此这里出现的任何字段名都必须与 harnessclient 的 wire 类型一致，不能引入
// app-server 形状（threadId、turns、items 之类）。
//
// 三条不变式：
//  1. 只读方法白名单之外的一切调用在本地拒绝，不触达 Harness。
//  2. 会话可见性只由 cwd + canonical scope 决定，且缺 cwd 一律 fail closed。
//  3. 请求里认不出的字段一律拒绝，而不是忽略——未知字段可能改写授权目标。

// 只读方法白名单。写方法（session/create、session/prompt、session/cancel、
// session/selectModel）与事件订阅（session/follow、$events、$events/result）
// 都不在这里：写路径必须继续走 agentd 自己那套幂等与授权，订阅走 WS 通道。
const (
	harnessNativeMethodSessionList         = "session/list"
	harnessNativeMethodSessionSearch       = "session/search"
	harnessNativeMethodSessionPage         = "session/page"
	harnessNativeMethodSessionModelCatalog = "session/modelCatalog"

	// H07 写路径。与只读方法分开登记、分开放行（见 harnessNativeWriteMethods）。
	harnessNativeMethodSessionCreate      = "session/create"
	harnessNativeMethodSessionSelectModel = "session/selectModel"
	harnessNativeMethodSessionPrompt      = "session/prompt"
	harnessNativeMethodSessionCancel      = "session/cancel"
)

// harnessNativeReadOnlyMethods 是**只读**方法集合。
//
// 用显式集合而不是前缀判断：session/create 与 session/cancel 都以 session/ 开头，
// 按前缀放行会把写方法一起放过去。
var harnessNativeReadOnlyMethods = map[string]struct{}{
	harnessNativeMethodSessionList:         {},
	harnessNativeMethodSessionSearch:       {},
	harnessNativeMethodSessionPage:         {},
	harnessNativeMethodSessionModelCatalog: {},
}

// harnessNativeWriteMethods 是**写**方法集合，与只读集合分开维护。
//
// 分成两个集合而不是一个"允许的方法"集合，是为了让"这条通道能不能改上游状态"成为
// 调用点的显式判断。合并成一个集合后，任何一次"顺手把某方法加进白名单"都会同时
// 扩大读写两侧；分开之后写侧要单独改、单独审。
//
// 注意这里**没有** `$events/result`：应答审批要走流通道（它绑定活连接的 clientId），
// 不是一条可以被单独调用的 RPC。单独开放它会绕开 clientId 关联。
var harnessNativeWriteMethods = map[string]struct{}{
	harnessNativeMethodSessionCreate:      {},
	harnessNativeMethodSessionSelectModel: {},
	harnessNativeMethodSessionPrompt:      {},
	harnessNativeMethodSessionCancel:      {},
}

// harnessNativeCWDScopedMethods 是接受 cwd 授权提示的方法。
//
// session/page 不接受：它的目标由 address.sessionId 决定，cwd 在这里既不是必需信息，
// 也不能改变授权结果，认下它只会多出一个可以试探的入口。session/modelCatalog 是
// 全局模型配置，本来就没有目录维度。
//
// session/create **接受** cwd：创建会话要落到某个目录，cwd 正是它的授权依据。
// 其余写方法不接受——它们的目标由 sessionId 决定，cwd 既非必需也不能改变授权结果。
var harnessNativeCWDScopedMethods = map[string]struct{}{
	harnessNativeMethodSessionList:   {},
	harnessNativeMethodSessionSearch: {},
	harnessNativeMethodSessionCreate: {},
}

// harnessNativePolicyError 是中继在触达 Harness 之前给出的拒绝。
//
// 用 HTTP 状态码而不是 result.ok=false 下发：这类拒绝不是上游的业务结论，混进
// result 里会让客户端把"越权"和"上游报错"当成同一类可降级情况处理。
type harnessNativePolicyError struct {
	status  int
	message string
}

func (e *harnessNativePolicyError) Error() string { return e.message }

func harnessNativeReject(status int, message string) *harnessNativePolicyError {
	return &harnessNativePolicyError{status: status, message: message}
}

// harnessNativePolicyStatus 取出拒绝对应的状态码；非策略错误按 500 处理。
func harnessNativePolicyStatus(err error) (int, string) {
	var policyErr *harnessNativePolicyError
	if errors.As(err, &policyErr) {
		return policyErr.status, policyErr.message
	}
	return http.StatusInternalServerError, "读取 Harness 失败"
}

// harnessNativeListArgs 是 session/list 的原生参数。
//
// wire 形参名带下划线（"_request"），原因见 harnessclient.SessionListRequest：
// Harness 的网关按描述符逐字校验形参名，改成 "request" 会拿到 gateway/arguments-invalid。
type harnessNativeListArgs struct {
	Request struct {
		Cursor string `json:"cursor,omitempty"`
	} `json:"_request,omitempty"`
}

// harnessNativeSearchArgs 是 session/search 的原生参数。注意这一条的形参名是
// "request"（无下划线），与 list 不同。
type harnessNativeSearchArgs struct {
	Request struct {
		Query string `json:"query"`
	} `json:"request"`
}

// harnessNativePageArgs 是 session/page 的原生参数。
//
// ThroughSeq 用指针：0 是合法取值（只读到 seq 0），省略才非法。用值类型会把
// "没传" 和 "传了 0" 混成同一种情况，而后者恰好是网关判定的必填项。
type harnessNativePageArgs struct {
	Request struct {
		Address struct {
			Kind      string `json:"kind"`
			SessionID string `json:"sessionId"`
		} `json:"address"`
		ThroughSeq  *int64 `json:"throughSeq"`
		BeforeSeq   int64  `json:"beforeSeq,omitempty"`
		MaxMessages int    `json:"maxMessages,omitempty"`
	} `json:"request"`
}

// --- H07 写路径的原生参数 ---

// harnessNativeCreateArgs 是 session/create 的原生参数。
//
// `cwd` 与 `workspaceId` 二选一（H00 实测：同时传两者会被 gateway/bad-request 拒绝）。
// 中继只开放 cwd：workspaceId 是 Harness 内部标识，移动端拿不到也不该猜。
// agentPreset 由 Harness 决定默认值——契约 D4 要求 create 默认省略它，
// 认下它等于让调用方去挑一个中继无法验证是否存在的 preset。
type harnessNativeCreateArgs struct {
	Request struct {
		CWD       string `json:"cwd,omitempty"`
		SessionID string `json:"sessionId,omitempty"`
	} `json:"request"`
}

// harnessNativeSelectModelArgs 是 session/selectModel 的原生参数。
//
// provider/model 取值域由 Harness 的模型目录决定，中继只做形状与非空校验，不按名字猜。
type harnessNativeSelectModelArgs struct {
	Request struct {
		SessionID       string `json:"sessionId"`
		Provider        string `json:"provider"`
		Model           string `json:"model"`
		ReasoningEffort string `json:"reasoningEffort,omitempty"`
	} `json:"request"`
}

// harnessNativePromptArgs 是 session/prompt 的原生参数。
//
// Content 原样透传（它是协议的判别联合，中继不该重写），但必须非空：
// 空内容会让上游把一次用户提交变成一次空回合。
type harnessNativePromptArgs struct {
	Request struct {
		RequestID      string            `json:"requestId"`
		SessionID      string            `json:"sessionId"`
		Mode           string            `json:"mode"`
		Content        []json.RawMessage `json:"content"`
		ClientTimeZone string            `json:"clientTimeZone,omitempty"`
	} `json:"request"`
}

// harnessNativeCancelArgs 是 session/cancel 的原生参数。
type harnessNativeCancelArgs struct {
	Request struct {
		SessionID string `json:"sessionId"`
	} `json:"request"`
}

// harnessNativeDecodeStrict 严格解码一段参数：未知字段直接失败，且只允许一个 JSON 值。
//
// 这是"未知字段涉及授权目标时 fail closed"的落点。放任未知字段通过，等于允许调用方
// 用中继不认识的键去改写上游的解析结果，而授权判断用的是中继自己的解析结果。
func harnessNativeDecodeStrict(raw json.RawMessage, target any) error {
	if len(raw) == 0 {
		return nil
	}
	decoder := json.NewDecoder(strings.NewReader(string(raw)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return errors.New("参数只能包含一个 JSON 值")
	}
	return nil
}

// harnessNativeParsedArgs 是一次已通过严格校验的调用参数。
//
// 分开保存"转发用参数"与"授权目标"是有意的：授权判断必须用中继自己解析出来的目标，
// 而不是让转发参数兼作授权依据——两者一旦混用，任何让上游解析结果与本地解析结果
// 不一致的输入都会变成越权。
type harnessNativeParsedArgs struct {
	// Forward 是要转发给 Harness 的原生参数对象。
	Forward any
	// SessionID 是本次调用的目标会话；零参数方法（list/modelCatalog/create）为空。
	SessionID string
	// Query 是 session/search 的关键词，其余方法为空。
	Query string
	// CreateCWD 是 session/create 的目标目录。创建时还没有 sessionId，
	// 授权依据只能是这个 cwd——它是 create 唯一可以据以判断"允许建在哪"的输入。
	CreateCWD string
}

// harnessNativeArgsForMethod 按方法严格解析参数，并返回转发参数与授权目标。
func harnessNativeArgsForMethod(method string, raw json.RawMessage) (harnessNativeParsedArgs, error) {
	switch method {
	case harnessNativeMethodSessionList:
		var args harnessNativeListArgs
		if err := harnessNativeDecodeStrict(raw, &args); err != nil {
			return harnessNativeParsedArgs{}, harnessNativeReject(http.StatusBadRequest, "session/list 参数非法："+err.Error())
		}
		return harnessNativeParsedArgs{Forward: map[string]any{"_request": args.Request}}, nil

	case harnessNativeMethodSessionSearch:
		var args harnessNativeSearchArgs
		if err := harnessNativeDecodeStrict(raw, &args); err != nil {
			return harnessNativeParsedArgs{}, harnessNativeReject(http.StatusBadRequest, "session/search 参数非法："+err.Error())
		}
		query := strings.TrimSpace(args.Request.Query)
		if query == "" {
			return harnessNativeParsedArgs{}, harnessNativeReject(http.StatusBadRequest, "session/search 的 query 不能为空")
		}
		if strings.ContainsRune(query, 0) {
			return harnessNativeParsedArgs{}, harnessNativeReject(http.StatusBadRequest, "session/search 的 query 不能包含 NUL")
		}
		return harnessNativeParsedArgs{
			Forward: map[string]any{"request": map[string]any{"query": query}},
			Query:   query,
		}, nil

	case harnessNativeMethodSessionPage:
		var args harnessNativePageArgs
		if err := harnessNativeDecodeStrict(raw, &args); err != nil {
			return harnessNativeParsedArgs{}, harnessNativeReject(http.StatusBadRequest, "session/page 参数非法："+err.Error())
		}
		sessionID := strings.TrimSpace(args.Request.Address.SessionID)
		if sessionID == "" {
			return harnessNativeParsedArgs{}, harnessNativeReject(http.StatusBadRequest, "session/page 必须给出 address.sessionId")
		}
		if kind := strings.TrimSpace(args.Request.Address.Kind); kind != "" && kind != "session" {
			// subagent 形态首版不开放，认下它等于放宽目标集合。
			return harnessNativeParsedArgs{}, harnessNativeReject(http.StatusBadRequest, "session/page 只支持 address.kind=session")
		}
		if args.Request.ThroughSeq == nil {
			// throughSeq 是必填：它必须来自本次 follow 开场 snapshot 的 cursor。
			// 省略会被 Harness 判为输入非法，本地先拒能给出可操作的文案。
			return harnessNativeParsedArgs{}, harnessNativeReject(http.StatusBadRequest, "session/page 必须给出 throughSeq")
		}
		if *args.Request.ThroughSeq < 0 || args.Request.BeforeSeq < 0 || args.Request.MaxMessages < 0 {
			return harnessNativeParsedArgs{}, harnessNativeReject(http.StatusBadRequest, "session/page 的游标与条数不能为负")
		}
		request := map[string]any{
			"address":    map[string]any{"kind": "session", "sessionId": sessionID},
			"throughSeq": *args.Request.ThroughSeq,
		}
		// Harness 把 beforeSeq=0 当成“从 seq 0 之前读取”，而不是“未提供”。
		// 只转发客户端实际给出的有效边界，避免完整历史被错误截成空页。
		if args.Request.BeforeSeq > 0 {
			request["beforeSeq"] = args.Request.BeforeSeq
		}
		if args.Request.MaxMessages > 0 {
			request["maxMessages"] = args.Request.MaxMessages
		}
		return harnessNativeParsedArgs{
			Forward:   map[string]any{"request": request},
			SessionID: sessionID,
		}, nil

	case harnessNativeMethodSessionModelCatalog:
		var args map[string]any
		if err := harnessNativeDecodeStrict(raw, &args); err != nil {
			return harnessNativeParsedArgs{}, harnessNativeReject(http.StatusBadRequest, "session/modelCatalog 参数非法："+err.Error())
		}
		if len(args) != 0 {
			return harnessNativeParsedArgs{}, harnessNativeReject(http.StatusBadRequest, "session/modelCatalog 不接受参数")
		}
		// 该方法描述符里没有参数，必须传空对象而不是省略。
		return harnessNativeParsedArgs{Forward: map[string]any{}}, nil

	case harnessNativeMethodSessionCreate:
		var args harnessNativeCreateArgs
		if err := harnessNativeDecodeStrict(raw, &args); err != nil {
			return harnessNativeParsedArgs{}, harnessNativeReject(http.StatusBadRequest, "session/create 参数非法："+err.Error())
		}
		cwd := strings.TrimSpace(args.Request.CWD)
		if cwd == "" {
			// 没有 cwd 就没有授权依据，也没有可回应的归属。缺它就拒绝，
			// 而不是让上游去创建在某个默认目录里——那会绕过中继的目录授权。
			return harnessNativeParsedArgs{}, harnessNativeReject(http.StatusBadRequest, "session/create 必须给出 cwd")
		}
		if strings.ContainsRune(cwd, 0) {
			return harnessNativeParsedArgs{}, harnessNativeReject(http.StatusBadRequest, "session/create 的 cwd 不能包含 NUL")
		}
		forward := map[string]any{"cwd": cwd}
		if sessionID := strings.TrimSpace(args.Request.SessionID); sessionID != "" {
			// 允许调用方指定 sessionId（用于本地乐观记录的稳定关联）。
			forward["sessionId"] = sessionID
		}
		// agentPreset 刻意不转发：由 Harness 决定默认值（契约 D4）。
		return harnessNativeParsedArgs{
			Forward:   map[string]any{"request": forward},
			CreateCWD: cwd,
		}, nil

	case harnessNativeMethodSessionSelectModel:
		var args harnessNativeSelectModelArgs
		if err := harnessNativeDecodeStrict(raw, &args); err != nil {
			return harnessNativeParsedArgs{}, harnessNativeReject(http.StatusBadRequest, "session/selectModel 参数非法："+err.Error())
		}
		sessionID := strings.TrimSpace(args.Request.SessionID)
		provider := strings.TrimSpace(args.Request.Provider)
		model := strings.TrimSpace(args.Request.Model)
		if sessionID == "" || provider == "" || model == "" {
			return harnessNativeParsedArgs{}, harnessNativeReject(http.StatusBadRequest, "session/selectModel 必须给出 sessionId、provider 与 model")
		}
		forward := map[string]any{"sessionId": sessionID, "provider": provider, "model": model}
		// reasoningEffort 是可选：只在确实给了非空值时才转发，
		// 否则会把"没选档位"变成一个显式的空档位。
		if effort := strings.TrimSpace(args.Request.ReasoningEffort); effort != "" {
			forward["reasoningEffort"] = effort
		}
		return harnessNativeParsedArgs{
			Forward:   map[string]any{"request": forward},
			SessionID: sessionID,
		}, nil

	case harnessNativeMethodSessionPrompt:
		var args harnessNativePromptArgs
		if err := harnessNativeDecodeStrict(raw, &args); err != nil {
			return harnessNativeParsedArgs{}, harnessNativeReject(http.StatusBadRequest, "session/prompt 参数非法："+err.Error())
		}
		sessionID := strings.TrimSpace(args.Request.SessionID)
		requestID := strings.TrimSpace(args.Request.RequestID)
		mode := strings.TrimSpace(args.Request.Mode)
		if sessionID == "" {
			return harnessNativeParsedArgs{}, harnessNativeReject(http.StatusBadRequest, "session/prompt 必须给出 sessionId")
		}
		if requestID == "" {
			// requestId 是提交与 durable user/message.source.rpcId 的关联键（契约 D4）。
			// 缺它就无法对账"这次提交到底落没落"，因此不允许省略。
			return harnessNativeParsedArgs{}, harnessNativeReject(http.StatusBadRequest, "session/prompt 必须给出 requestId")
		}
		// mode 的取值域实测只有 queue 与 steer（传 default 会被上游判输入非法）。
		if mode != harnessNativePromptModeQueue && mode != harnessNativePromptModeSteer {
			return harnessNativeParsedArgs{}, harnessNativeReject(http.StatusBadRequest, "session/prompt 的 mode 只能是 queue 或 steer")
		}
		if len(args.Request.Content) == 0 {
			return harnessNativeParsedArgs{}, harnessNativeReject(http.StatusBadRequest, "session/prompt 的 content 不能为空")
		}
		forward := map[string]any{
			"requestId": requestID,
			"sessionId": sessionID,
			"mode":      mode,
			"content":   args.Request.Content,
		}
		if tz := strings.TrimSpace(args.Request.ClientTimeZone); tz != "" {
			forward["clientTimeZone"] = tz
		}
		return harnessNativeParsedArgs{
			Forward:   map[string]any{"request": forward},
			SessionID: sessionID,
		}, nil

	case harnessNativeMethodSessionCancel:
		var args harnessNativeCancelArgs
		if err := harnessNativeDecodeStrict(raw, &args); err != nil {
			return harnessNativeParsedArgs{}, harnessNativeReject(http.StatusBadRequest, "session/cancel 参数非法："+err.Error())
		}
		sessionID := strings.TrimSpace(args.Request.SessionID)
		if sessionID == "" {
			return harnessNativeParsedArgs{}, harnessNativeReject(http.StatusBadRequest, "session/cancel 必须给出 sessionId")
		}
		return harnessNativeParsedArgs{
			Forward:   map[string]any{"request": map[string]any{"sessionId": sessionID}},
			SessionID: sessionID,
		}, nil
	}
	return harnessNativeParsedArgs{}, harnessNativeReject(http.StatusForbidden, "不支持的 Harness 方法")
}

// session/prompt 的 mode 取值域。实测（隔离 Harness 0.1.5-rc.2）只有这两个；
// 契约文档只写了字段名没写取值，这里以实跑为准。
const (
	harnessNativePromptModeQueue = "queue"
	harnessNativePromptModeSteer = "steer"
)

// harnessNativeRequestedScope 把请求里的 cwd 提示解析成授权作用域。
//
// cwd 只用于中继授权：它既决定"能看见哪些会话"，也决定"这次调用的目标目录是否被授权"。
// 它不参与转发——上游 args 由 harnessNativeArgsForMethod 单独构造，cwd 不会被带进去。
// 伪造的 cwd（不在 projects allowlist 也不在 browse_roots）在这里就被拒。
func (r *Router) harnessNativeRequestedScope(method string, cwd string) (*gatewayScope, error) {
	trimmed := strings.TrimSpace(cwd)
	if trimmed == "" {
		return nil, nil
	}
	if _, ok := harnessNativeCWDScopedMethods[method]; !ok {
		return nil, harnessNativeReject(http.StatusBadRequest, "该方法不接受 cwd")
	}
	scope, ok := r.gatewayScopeForPath(trimmed)
	if !ok {
		// 路径穿越、指向 allowlist 之外的目录、符号链接指向未授权位置都落到这里。
		return nil, harnessNativeReject(http.StatusForbidden, "cwd 必须来自 projects allowlist 或 browse_roots")
	}
	return &scope, nil
}

// harnessNativeVisibleSessions 取回会话列表并按授权作用域裁剪。
//
// scope 非空时只保留该目录下的会话；scope 为空表示"受控全局发现"——逐行重新映射
// 授权作用域，命不中的直接丢弃。两种情况都要求会话带 cwd：拿不到 cwd 就无法证明
// 归属，不能因为"读的是列表"就放行。
func (r *Router) harnessNativeVisibleSessions(
	ctx context.Context,
	upstream harnessNativeRPCUpstream,
	scope *gatewayScope,
) ([]harnessclient.SessionSummary, error) {
	sessions, err := upstream.ListSessions(ctx, harnessclient.SessionListRequest{})
	if err != nil {
		return nil, err
	}
	visible := make([]harnessclient.SessionSummary, 0, len(sessions))
	for _, session := range sessions {
		if strings.TrimSpace(session.CWD) == "" {
			// 没有 cwd 的会话无法证明属于授权工作区，fail closed。
			continue
		}
		if session.Blank {
			// 与 DeepSeek gateway 的列表语义保持一致：还没有任何轮次的会话不在列表里展示。
			// 中继换的是传输方式，不是用户看到的会话集合。
			continue
		}
		if scope != nil {
			if !gatewayScopeContainsPath(*scope, session.CWD) {
				continue
			}
		} else if _, ok := r.gatewayScopeForPath(session.CWD); !ok {
			// 无 cwd 请求只代表受控全局发现，不代表全局授权。逐行重新映射授权作用域，
			// 不能把另一个本机会话的 cwd 借列表响应泄露给移动端。
			continue
		}
		visible = append(visible, session)
	}
	// 最近活动的在前，与 Mimi 侧栏的"最近"一致。
	sort.SliceStable(visible, func(i, j int) bool { return visible[i].UpdatedAt > visible[j].UpdatedAt })
	return visible, nil
}

// harnessNativeAuthorizeSession 判定目标会话是否落在授权范围内。
//
// 会话的 cwd 只能从上游会话列表取：中继不接受调用方自报的 cwd 作为该会话的归属证据，
// 否则伪造一个 cwd 就能读到任意会话。列表里找不到该会话时同样拒绝——拿不到摘要就
// 无法证明它属于授权工作区。
func (r *Router) harnessNativeAuthorizeSession(
	ctx context.Context,
	upstream harnessNativeRPCUpstream,
	sessionID string,
	scope *gatewayScope,
) error {
	sessions, err := upstream.ListSessions(ctx, harnessclient.SessionListRequest{})
	if err != nil {
		return err
	}
	for _, session := range sessions {
		if session.SessionID != sessionID {
			continue
		}
		if strings.TrimSpace(session.CWD) == "" {
			return harnessNativeReject(http.StatusForbidden, "目标会话缺少 cwd，无法确认授权")
		}
		if scope != nil {
			if !gatewayScopeContainsPath(*scope, session.CWD) {
				return harnessNativeReject(http.StatusForbidden, "目标会话不在授权目录内")
			}
			return nil
		}
		if _, ok := r.gatewayScopeForPath(session.CWD); !ok {
			return harnessNativeReject(http.StatusForbidden, "目标会话不在授权目录内")
		}
		return nil
	}
	return harnessNativeReject(http.StatusForbidden, "目标会话不存在或不可见")
}

// harnessNativeSearchRow 是一条已通过授权校验的检索命中。
type harnessNativeSearchRow struct {
	SessionID string `json:"sessionId"`
	Snippet   string `json:"snippet"`
}

// harnessNativeSearchResult 是检索结果的原生形状。
type harnessNativeSearchResult struct {
	Items   []harnessNativeSearchRow `json:"items"`
	HasMore bool                     `json:"hasMore"`
}

// harnessNativeSearchLocalCap 限制本地降级匹配返回的行数，与 DeepSeek gateway 同量级。
const harnessNativeSearchLocalCap = 50

// harnessNativeSearch 执行检索并裁剪命中。
//
// 顺序是硬要求：先按 sessionId 取回可信会话摘要、证明该会话属于授权工作区，之后才允许
// 把 snippet 放进响应。反过来先回 snippet 再校验，等于把未授权会话的内容先发出去一次。
//
// 检索索引是宿主侧的可选配置：未挂载时 Harness 返回 gateway/internal，这里退化为在
// **已授权列表内**做本地包含匹配。降级只在已授权集合里发生，不会扩大可见范围。
func (r *Router) harnessNativeSearch(
	ctx context.Context,
	upstream harnessNativeRPCUpstream,
	query string,
	scope *gatewayScope,
) (harnessNativeSearchResult, error) {
	sessions, err := r.harnessNativeVisibleSessions(ctx, upstream, scope)
	if err != nil {
		return harnessNativeSearchResult{}, err
	}
	visible := make(map[string]harnessclient.SessionSummary, len(sessions))
	for _, session := range sessions {
		visible[session.SessionID] = session
	}

	if result, searchErr := upstream.SearchSessions(ctx, query); searchErr == nil {
		rows := make([]harnessNativeSearchRow, 0, len(result.Items))
		for _, item := range result.Items {
			// 摘要缺失说明该会话不在已授权列表里，直接丢弃。
			if _, ok := visible[item.SessionID]; !ok {
				continue
			}
			rows = append(rows, harnessNativeSearchRow{SessionID: item.SessionID, Snippet: item.Snippet})
		}
		return harnessNativeSearchResult{Items: rows, HasMore: false}, nil
	} else if !harnessNativeSearchIndexUnavailable(searchErr) {
		// 上游真的出错了就如实上报，不拿"本地匹配"把故障盖过去。
		return harnessNativeSearchResult{}, searchErr
	}

	needle := strings.ToLower(query)
	rows := make([]harnessNativeSearchRow, 0, 16)
	for _, session := range sessions {
		haystack, snippet := harnessNativeSearchHaystack(session)
		if !strings.Contains(haystack, needle) {
			continue
		}
		rows = append(rows, harnessNativeSearchRow{SessionID: session.SessionID, Snippet: snippet})
		if len(rows) >= harnessNativeSearchLocalCap {
			break
		}
	}
	return harnessNativeSearchResult{Items: rows, HasMore: false}, nil
}

// harnessNativeSearchIndexUnavailable 判定上游错误是不是"检索索引未启用"。
//
// 只认 code：0.1.5-rc.2 与 0.1.6-alpha.2 的降级文案不同（disabled + openAt vs
// unavailable + 未挂载 provider），按文案匹配会在版本变化时静默失效。
func harnessNativeSearchIndexUnavailable(err error) bool {
	var remoteErr *harnessclient.RemoteError
	if !errors.As(err, &remoteErr) {
		return false
	}
	return remoteErr.Code == "gateway/internal"
}

// harnessNativeSearchHaystack 拼出参与本地匹配的文本与可展示的命中摘要。
func harnessNativeSearchHaystack(session harnessclient.SessionSummary) (string, string) {
	if session.Projections == nil {
		return strings.ToLower(session.SessionID), ""
	}
	values := session.Projections.Values
	title := strings.TrimSpace(values.Title)
	snippet := title
	parts := []string{title, session.SessionID}
	for index := len(values.TurnOutline) - 1; index >= 0; index-- {
		outline := values.TurnOutline[index]
		parts = append(parts, outline.Prompt, outline.Response)
		if snippet == "" {
			snippet = harnessNativeFirstNonEmpty(outline.Prompt, outline.Response)
		}
	}
	return strings.ToLower(strings.Join(parts, "\n")), snippet
}

func harnessNativeFirstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

// harnessNativeListValue 是列表响应的原生形状。
type harnessNativeListValue struct {
	Items []harnessclient.SessionSummary `json:"items"`
}

// harnessNativeList 返回按授权裁剪后的会话列表。
func (r *Router) harnessNativeList(
	ctx context.Context,
	upstream harnessNativeRPCUpstream,
	scope *gatewayScope,
) (harnessNativeListValue, error) {
	sessions, err := r.harnessNativeVisibleSessions(ctx, upstream, scope)
	if err != nil {
		return harnessNativeListValue{}, err
	}
	return harnessNativeListValue{Items: sessions}, nil
}

// harnessNativeMarshalValue 把本地构造的原生结果编码回原始 JSON。
//
// 编回去而不是让上层复用请求里的字节：列表与检索都经过裁剪，响应必须反映裁剪后的
// 结果；编码用的又都是 harnessclient 的原生类型，所以字段名不会被改成 app-server 形状。
func harnessNativeMarshalValue(value any) (json.RawMessage, error) {
	raw, err := json.Marshal(value)
	if err != nil {
		return nil, fmt.Errorf("编码原生结果失败：%w", err)
	}
	return raw, nil
}

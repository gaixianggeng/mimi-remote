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
)

// harnessNativeReadOnlyMethods 是中继允许的方法全集。
//
// 用显式集合而不是前缀判断：session/create 与 session/cancel 都以 session/ 开头，
// 按前缀放行会把写方法一起放过去。
var harnessNativeReadOnlyMethods = map[string]struct{}{
	harnessNativeMethodSessionList:         {},
	harnessNativeMethodSessionSearch:       {},
	harnessNativeMethodSessionPage:         {},
	harnessNativeMethodSessionModelCatalog: {},
}

// harnessNativeCWDScopedMethods 是接受 cwd 授权提示的方法。
//
// session/page 不接受：它的目标由 address.sessionId 决定，cwd 在这里既不是必需信息，
// 也不能改变授权结果，认下它只会多出一个可以试探的入口。session/modelCatalog 是
// 全局模型配置，本来就没有目录维度。
var harnessNativeCWDScopedMethods = map[string]struct{}{
	harnessNativeMethodSessionList:   {},
	harnessNativeMethodSessionSearch: {},
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
	// SessionID 是 session/page 的目标会话，其余方法为空。
	SessionID string
	// Query 是 session/search 的关键词，其余方法为空。
	Query string
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
		return harnessNativeParsedArgs{
			Forward: map[string]any{"request": map[string]any{
				"address":     map[string]any{"kind": "session", "sessionId": sessionID},
				"throughSeq":  *args.Request.ThroughSeq,
				"beforeSeq":   args.Request.BeforeSeq,
				"maxMessages": args.Request.MaxMessages,
			}},
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
	}
	return harnessNativeParsedArgs{}, harnessNativeReject(http.StatusForbidden, "不支持的 Harness 方法")
}

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

package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

// 本文件是 /api/harness/rpc：移动端原生消费 Harness 的只读中继。
//
// 它存在的理由不是"少写一层翻译"，而是移动端不能直连 Harness：启动 token 换成
// Cookie 的握手、cwd → 工作区授权、会话可见性裁剪都必须在 agentd 侧完成。因此中继
// 只做三件事——认证、授权、把原生结果原样带回；它不做协议翻译（那是 DeepSeek
// gateway 的活），也不做无条件的反向代理（那样等于把 Harness 的全部方法开放给移动端）。

// harnessNativeRPCRequestBodyMaxBytes 限制中继请求体积。
//
// 请求只承载一个方法名、一小段参数和一个 cwd 提示，64 KiB 已远超正常用量。这里比默认的
// 256 KiB 更紧：中继是唯一一条把移动端输入直接拼进上游请求的通道，收紧上限能把
// "用超大参数打上游"这类试探挡在本地，也顺带限制伪造 Content-Length 的收益。
const harnessNativeRPCRequestBodyMaxBytes int64 = 64 << 10

// harnessNativeRPCUpstream 是中继对 Harness 的最小依赖面。
//
// 只声明中继真正会调用的三个能力：列表、检索、原始 RPC。写方法不在接口上，因此即使
// 上层逻辑写错，也不存在"顺手调一次 session/prompt"的可能。生产实现是
// *harnessclient.Client；测试注入 Spy，用来断言被拒的操作从未触达上游。
type harnessNativeRPCUpstream interface {
	ListSessions(ctx context.Context, request harnessclient.SessionListRequest) ([]harnessclient.SessionSummary, error)
	SearchSessions(ctx context.Context, query string) (harnessclient.SessionSearchResult, error)
	CallRaw(ctx context.Context, method string, args any) (json.RawMessage, error)
}

// harnessNativeRPCRequest 是中继的请求体。
//
// 字段刻意保持原生形状：args 直接对应 Harness 的形参对象（list 用 "_request"，
// search/page 用 "request"），响应里的 value 也按原生字段下发。中继不引入
// app-server 的 threadId/turns/items 之类形状，否则就又造了一套需要长期维护的协议。
type harnessNativeRPCRequest struct {
	// RPCID 由调用方给出并原样回传，用于把响应关联回请求。
	RPCID string `json:"rpcId"`
	// Method 必须是 harnessNativeReadOnlyMethods 里的只读方法。
	Method string `json:"method"`
	// Args 是该方法的原生参数对象，按方法严格校验，未知字段直接拒绝。
	Args json.RawMessage `json:"args,omitempty"`
	// CWD 只参与中继授权（决定能看见哪些会话），不进上游 args。
	CWD string `json:"cwd,omitempty"`
}

// harnessNativeRPCResponse 是中继的响应体，沿用 Connection RPC 的外壳。
//
// 保留 type/rpcId/result.ok 这一层是刻意的：客户端可以用与直连 Harness 相同的判定
// 逻辑处理业务失败（HTTP 200 + result.ok=false 仍是失败），不需要为"经由 agentd"
// 再学一套错误语义。
type harnessNativeRPCResponse struct {
	Type   string                     `json:"type"`
	RPCID  string                     `json:"rpcId"`
	Result harnessNativeRPCResultBody `json:"result"`
}

type harnessNativeRPCResultBody struct {
	OK    bool                   `json:"ok"`
	Value json.RawMessage        `json:"value,omitempty"`
	Error *harnessNativeRPCError `json:"error,omitempty"`
}

// harnessNativeRPCError 是上游业务错误的外壳。字段名与 Harness 一致（details 而非 data）。
type harnessNativeRPCError struct {
	Code    string          `json:"code,omitempty"`
	Message string          `json:"message,omitempty"`
	Details json.RawMessage `json:"details,omitempty"`
}

// harnessNativeRPCHandler 处理 POST /api/harness/rpc。
//
// 顺序是安全边界的一部分：先做全部本地校验（method、origin、体积、参数、cwd 授权），
// 再解析上游连接。被拒的请求因此不会产生任何一次 Harness 访问，也就没有"靠被拒请求
// 探测上游是否存在"的旁路。
func (r *Router) harnessNativeRPCHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	// 认证中间件只证明"请求方持有本机配对的 token"，不证明"请求来自我们自己的页面"。
	// 同源校验与它组成同一条 fail-closed 边界。
	if !sameOriginOrNoOrigin(req) {
		writeError(w, http.StatusForbidden, "origin 不被允许")
		return
	}

	payload, ok := readHarnessNativeRPCRequest(w, req)
	if !ok {
		return
	}
	rpcID := strings.TrimSpace(payload.RPCID)
	if rpcID == "" {
		writeError(w, http.StatusBadRequest, "rpcId 不能为空")
		return
	}
	method := strings.TrimSpace(payload.Method)
	_, readOnly := harnessNativeReadOnlyMethods[method]
	_, write := harnessNativeWriteMethods[method]
	if !readOnly && !write {
		// 订阅（follow/$events/$events/result）与其余未知方法都在这里被拒。
		writeError(w, http.StatusForbidden, "该 Harness 方法不开放")
		return
	}
	parsed, err := harnessNativeArgsForMethod(method, payload.Args)
	if err != nil {
		writeHarnessNativeFailure(w, err)
		return
	}
	scope, err := r.harnessNativeRequestedScope(method, payload.CWD)
	if err != nil {
		writeHarnessNativeFailure(w, err)
		return
	}

	ctx := req.Context()
	upstream, err := r.harnessNativeUpstreamFor(ctx)
	if err != nil {
		writeHarnessNativeFailure(w, err)
		return
	}

	// 写路径单独分流：它的授权前置条件与只读不同（见 harnessNativeForwardWrite）。
	if write {
		r.harnessNativeForwardWrite(w, ctx, upstream, rpcID, method, parsed, scope)
		return
	}

	switch method {
	case harnessNativeMethodSessionList:
		value, listErr := r.harnessNativeList(ctx, upstream, scope)
		if listErr != nil {
			writeHarnessNativeUpstreamFailure(w, rpcID, listErr)
			return
		}
		raw, marshalErr := harnessNativeMarshalValue(value)
		if marshalErr != nil {
			writeHarnessNativeFailure(w, marshalErr)
			return
		}
		writeHarnessNativeResult(w, rpcID, raw)

	case harnessNativeMethodSessionSearch:
		value, searchErr := r.harnessNativeSearch(ctx, upstream, parsed.Query, scope)
		if searchErr != nil {
			writeHarnessNativeUpstreamFailure(w, rpcID, searchErr)
			return
		}
		raw, marshalErr := harnessNativeMarshalValue(value)
		if marshalErr != nil {
			writeHarnessNativeFailure(w, marshalErr)
			return
		}
		writeHarnessNativeResult(w, rpcID, raw)

	case harnessNativeMethodSessionPage:
		// 授权检查必须先于转发：目标会话的归属只能由上游摘要证明，
		// 调用方自报的 cwd 不构成证据。
		if authErr := r.harnessNativeAuthorizeSession(ctx, upstream, parsed.SessionID, scope); authErr != nil {
			writeHarnessNativeFailure(w, authErr)
			return
		}
		// 原样透传：页的形状（records/hasMore 与 snapshot throughSeq 契约）由 Harness
		// 决定，中继不重建 turns/items 之类的分页投影。
		raw, pageErr := upstream.CallRaw(ctx, harnessclient.MethodSessionPage, parsed.Forward)
		if pageErr != nil {
			writeHarnessNativeUpstreamFailure(w, rpcID, pageErr)
			return
		}
		writeHarnessNativeResult(w, rpcID, raw)

	case harnessNativeMethodSessionModelCatalog:
		raw, catalogErr := upstream.CallRaw(ctx, harnessclient.MethodSessionModelCatalog, parsed.Forward)
		if catalogErr != nil {
			writeHarnessNativeUpstreamFailure(w, rpcID, catalogErr)
			return
		}
		writeHarnessNativeResult(w, rpcID, raw)
	}
}

// harnessNativeForwardWrite 转发一次写方法，并在此之前完成它的授权前置。
//
// 写路径与只读的根本区别：**只读的越权后果是"看见了不该看的"，写路径的是"改了不该改的"**。
// 因此这里对每个目标会话都要求一次上游归属证明（harnessNativeAuthorizeSession），
// 而不是像 session/list 那样"按 scope 裁剪结果"——裁剪对一个会改变上游状态的调用没有意义。
//
// 两类授权依据：
//   - session/create：目标还不存在，只能按 cwd 授权。cwd 已在解析阶段非空校验，
//     并在 scope 解析阶段被验为 projects allowlist / browse_roots 之内。
//   - 其余三个：按 sessionId 授权，且**必须**拿到上游摘要证明归属；
//     证明不了就不转发（宁可不做事，也不猜一个目标去做）。
func (r *Router) harnessNativeForwardWrite(
	w http.ResponseWriter,
	ctx context.Context,
	upstream harnessNativeRPCUpstream,
	rpcID string,
	method string,
	parsed harnessNativeParsedArgs,
	scope *gatewayScope,
) {
	if method == harnessNativeMethodSessionCreate {
		// create 的授权依据是 cwd：它必须落在本次请求声明的 scope 内。
		if scope == nil || strings.TrimSpace(parsed.CreateCWD) == "" {
			writeHarnessNativeFailure(w, harnessNativeReject(
				http.StatusForbidden, "session/create 需要落在已授权目录内"))
			return
		}
		if !r.harnessNativeCreateAllowed(parsed.CreateCWD, *scope) {
			writeHarnessNativeFailure(w, harnessNativeReject(
				http.StatusForbidden, "session/create 的目标目录不在本次授权范围内"))
			return
		}
		r.harnessNativeCallWrite(w, ctx, upstream, rpcID, method, parsed.Forward)
		return
	}

	// 其余写方法：目标会话归属必须被上游证明。
	if parsed.SessionID == "" {
		writeHarnessNativeFailure(w, harnessNativeReject(http.StatusBadRequest, "缺少目标会话"))
		return
	}
	if authErr := r.harnessNativeAuthorizeSession(ctx, upstream, parsed.SessionID, scope); authErr != nil {
		writeHarnessNativeFailure(w, authErr)
		return
	}
	r.harnessNativeCallWrite(w, ctx, upstream, rpcID, method, parsed.Forward)
}

// harnessNativeCallWrite 执行转发并把结果原样下发。
//
// 写方法的**业务失败**（HTTP 200 + result.ok=false）与只读同样处理：如实回给客户端，
// 让它自己决定是否降级。传输层失败才是 502——那种情况连"上游说了什么"都拿不到。
func (r *Router) harnessNativeCallWrite(
	w http.ResponseWriter,
	ctx context.Context,
	upstream harnessNativeRPCUpstream,
	rpcID string,
	method string,
	forward any,
) {
	raw, err := upstream.CallRaw(ctx, method, forward)
	if err != nil {
		writeHarnessNativeUpstreamFailure(w, rpcID, err)
		return
	}
	writeHarnessNativeResult(w, rpcID, raw)
}

// harnessNativeCreateAllowed 判断 create 的目标目录是否落在本次声明的授权范围内。
//
// 直接复用 `gatewayScopeContainsPath`：它先 `EvalSymlinks` 再按路径分量比较，
// 因此符号链接、`..`、以及 `/a/bc` 被 `/a/b` 误放行这几类输入都已覆盖。
// 不另写一份路径比较——那种"看起来等价"的重复实现正是越权的常见来源。
func (r *Router) harnessNativeCreateAllowed(cwd string, scope gatewayScope) bool {
	return gatewayScopeContainsPath(scope, cwd)
}

// 体积先按 Content-Length 预判、再用 LimitReader 兜底：伪造或缺失 Content-Length 的
// chunked 请求同样会被截断在同一个上限，且多读一个字节用于判定"确实超限"。
func readHarnessNativeRPCRequest(w http.ResponseWriter, req *http.Request) (harnessNativeRPCRequest, bool) {
	var payload harnessNativeRPCRequest
	if req.ContentLength > harnessNativeRPCRequestBodyMaxBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "请求体过大")
		return payload, false
	}
	body, err := io.ReadAll(io.LimitReader(req.Body, harnessNativeRPCRequestBodyMaxBytes+1))
	if err != nil {
		writeError(w, http.StatusBadRequest, "读取请求体失败")
		return payload, false
	}
	if int64(len(body)) > harnessNativeRPCRequestBodyMaxBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "请求体过大")
		return payload, false
	}
	decoder := json.NewDecoder(strings.NewReader(string(body)))
	// 顶层未知字段同样 fail closed：认不出的键可能改写授权目标。
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&payload); err != nil {
		writeError(w, http.StatusBadRequest, "请求体不是合法 JSON")
		return payload, false
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		writeError(w, http.StatusBadRequest, "请求体只能包含一个 JSON 值")
		return payload, false
	}
	return payload, true
}

// harnessNativeUpstreamFor 解析本次调用要用的上游连接。
//
// 每次调用单独认证一次，不跨请求复用 Cookie：Cookie 绑定 hostname+port 且有生命周期，
// 缓存它就要处理失效与撤权两条回收路径；而这里是回环上的本地服务，多一次
// GET /?token= 的代价远小于多一份需要失效的共享状态。撤权因此天然生效——Harness
// 一旦不再认可该 token，下一次调用就在这里失败。
func (r *Router) harnessNativeUpstreamFor(ctx context.Context) (harnessNativeRPCUpstream, error) {
	if r.harnessNativeUpstream != nil {
		// 测试接缝：注入 Spy 后不会发生任何真实网络访问。
		return r.harnessNativeUpstream(ctx)
	}
	return r.harnessNativeClientFor(ctx)
}

// harnessNativeClientFor 构造一个已完成认证的 Harness 客户端。
//
// 抽出来给流中继复用：它既需要 Connection RPC（取会话摘要做授权），也需要
// remote.mux 订阅能力，因此不能只依赖 harnessNativeRPCUpstream 那三个方法。
// 认证与脱敏策略与只读中继完全一致，两条通道不各写一份。
func (r *Router) harnessNativeClientFor(ctx context.Context) (*harnessclient.Client, error) {
	cfg := r.cfg.DeepSeek
	if !cfg.Enabled {
		return nil, harnessNativeReject(http.StatusServiceUnavailable, "DeepSeek Harness runtime 未启用")
	}
	baseURL, err := config.NormalizeDeepSeekBaseURL(cfg.BaseURL)
	if err != nil || baseURL == "" {
		return nil, harnessNativeReject(http.StatusServiceUnavailable, "deepseek.base_url 不可用，请在电脑运行 agentd doctor")
	}
	token, err := harnessclient.ReadTokenFile(cfg.TokenFile)
	if err != nil {
		// 错误里含本机绝对路径：日志记原因，回给移动端的只有可操作文案。
		log.Printf("harness native rpc 读取 token 文件失败 err=%v", err)
		return nil, harnessNativeReject(http.StatusServiceUnavailable, "读取 Harness 凭据失败，请在电脑运行 agentd doctor")
	}
	client, err := harnessclient.New(harnessclient.Config{BaseURL: baseURL, AccessToken: token})
	if err != nil {
		return nil, harnessNativeReject(http.StatusServiceUnavailable, "deepseek.base_url 不可用，请在电脑运行 agentd doctor")
	}
	if err := client.Authenticate(ctx); err != nil {
		// harnessclient 已保证传输层错误里不含启动 token，这里再收敛一次长度与关键词。
		log.Printf("harness native rpc 认证失败 err=%s", sanitizeGatewayDiagnostic(err.Error()))
		return nil, harnessNativeReject(http.StatusBadGateway, "无法连接 Harness 服务，请在电脑运行 agentd doctor")
	}
	return client, nil
}

// writeHarnessNativeResult 下发一次成功的只读结果。
func writeHarnessNativeResult(w http.ResponseWriter, rpcID string, value json.RawMessage) {
	writeJSON(w, http.StatusOK, harnessNativeRPCResponse{
		Type:   "server-response",
		RPCID:  rpcID,
		Result: harnessNativeRPCResultBody{OK: true, Value: value},
	})
}

// writeHarnessNativeFailure 下发一次本地拒绝。
//
// 本地拒绝用 HTTP 状态码而不是 result.ok=false：它不是上游的业务结论，混进 result 会让
// 客户端把"越权/参数非法"当成可降级的上游故障处理。响应仍带 rpcId，便于客户端对账。
func writeHarnessNativeFailure(w http.ResponseWriter, err error) {
	status, message := harnessNativePolicyStatus(err)
	writeError(w, status, message)
}

// writeHarnessNativeUpstreamFailure 下发一次上游结果。
//
// 上游的**业务**失败按原生语义处理：HTTP 200 + result.ok=false，客户端据此走与直连
// Harness 相同的降级分支（例如检索索引未启用时的能力隐藏）。传输层失败才是 HTTP 502，
// 因为它连"上游说了什么"都拿不到。
func writeHarnessNativeUpstreamFailure(w http.ResponseWriter, rpcID string, err error) {
	var remoteErr *harnessclient.RemoteError
	if errors.As(err, &remoteErr) {
		writeJSON(w, http.StatusOK, harnessNativeRPCResponse{
			Type:  "server-response",
			RPCID: rpcID,
			Result: harnessNativeRPCResultBody{
				OK: false,
				Error: &harnessNativeRPCError{
					Code:    remoteErr.Code,
					Message: remoteErr.Message,
					Details: remoteErr.Details,
				},
			},
		})
		return
	}
	log.Printf("harness native rpc 上游失败 err=%s", sanitizeGatewayDiagnostic(err.Error()))
	writeError(w, http.StatusBadGateway, "无法连接 Harness 服务，请在电脑运行 agentd doctor")
}

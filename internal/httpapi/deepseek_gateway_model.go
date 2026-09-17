package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"strings"

	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

// 本文件把移动端在一次 turn/start 里表达的模型与推理档位落到 Harness 会话上。
//
// 为什么不能忽略：policy 明确让 model / effort 通过参数门禁，移动端也总会在每条
// turn/start 上带上它们。适配层先前把两者整条丢掉，于是"用户在界面里选了模型"与
// "Harness 用了它自己的默认模型"之间没有任何提示——用户看到的选择和实际执行的选择
// 不是同一个，而且不报错，只能从回答风格上猜。
//
// 因此这里的出口只有两个：要么真的把选择交给 Harness，要么明确拒绝。没有静默忽略。

// deepSeekRequestedSelection 是客户端在一次 turn/start 里表达的模型选择。
type deepSeekRequestedSelection struct {
	Model    string
	Provider string
	Effort   string
}

// deepSeekTurnSelectionParams 取出本次请求声明的模型选择。
//
// modelProvider 只有部分客户端会带（Mimi 的 iOS 端把 provider 放在 thread/start 上），
// 因此它是提示而不是必需项，缺失时由模型目录补齐。
func deepSeekTurnSelectionParams(params map[string]any) deepSeekRequestedSelection {
	model, _ := gatewayStringParam(params, "model")
	provider, _ := gatewayStringParam(params, "modelProvider")
	effort, _ := gatewayStringParam(params, "effort")
	return deepSeekRequestedSelection{
		Model:    strings.TrimSpace(model),
		Provider: strings.TrimSpace(provider),
		Effort:   strings.TrimSpace(effort),
	}
}

// deepSeekModelSelectionError 是模型选择被拒时的用户可见原因。
//
// 单独一个类型是为了与"调用失败"分开：被拒的原因是用户能据此改选择的（模型不在目录里、
// 档位不支持），必须原样回给移动端；而目录读不到、selectModel 传输失败这类原因不能带上游
// 细节，只能回固定文案。
type deepSeekModelSelectionError struct{ message string }

func (e *deepSeekModelSelectionError) Error() string { return e.message }

// deepSeekCatalogMatch 是目录里匹配到的一个模型及其 provider。
type deepSeekCatalogMatch struct {
	Provider string
	Model    harnessclient.ModelEntry
}

// deepSeekCatalogLookup 在 Harness 模型目录里按模型 id 找条目。
//
// 必须查目录而不是自己拼 provider：session/selectModel 的 provider 是必填项，而移动端的
// turn/start 通常只带 model。供应商由模型名反推会把用户选到另一条计费路线上，因此这里只认
// 目录给的事实。
//
// 没有 providerHint 时**不取第一个命中项**：模型目录按 provider 逐个列举
// （buildModelCatalog 遍历全部 provider），没有任何机制保证 model id 全局唯一。同一个 id
// 出现在多个 provider 下时，候选会原样返回，由调用方决定是拒绝还是另有依据。
//
// 返回值：providerHint 给出时只在那个分组里找，找到即 ok；没给出时要求唯一命中，
// 多个命中返回候选列表且 ok 为 false。
func deepSeekCatalogLookup(
	catalog harnessclient.ModelCatalogResult,
	modelID string,
	providerHint string,
) (deepSeekCatalogMatch, []string, bool) {
	modelID = strings.TrimSpace(modelID)
	if modelID == "" {
		return deepSeekCatalogMatch{}, nil, false
	}
	providerHint = strings.TrimSpace(providerHint)
	var candidates []string
	var unique deepSeekCatalogMatch
	for _, group := range catalog.Groups {
		groupID := strings.TrimSpace(group.ID)
		if providerHint != "" && !strings.EqualFold(groupID, providerHint) {
			continue
		}
		for _, model := range group.Models {
			if !strings.EqualFold(strings.TrimSpace(model.ID), modelID) {
				continue
			}
			match := deepSeekCatalogMatch{Provider: group.ID, Model: model}
			if providerHint != "" {
				return match, []string{groupID}, true
			}
			candidates = append(candidates, groupID)
			unique = match
		}
	}
	if providerHint != "" {
		// 提示指不到这个模型：交由调用方按"该 provider 未声明它"处理，不换一个 provider
		// 顶上——那正是用户明确指定供应商时要避免的事。
		return deepSeekCatalogMatch{}, nil, false
	}
	if len(candidates) != 1 {
		return deepSeekCatalogMatch{}, candidates, false
	}
	return unique, candidates, true
}

// deepSeekSelection 是会话自身记录下来的模型选择。
type deepSeekSelection struct {
	Provider string
	Model    string
	Effort   string
}

// deepSeekSessionSelection 从会话自己的持久记录里读出当前的模型选择。
//
// 依据 Harness 自己的投影口径（model-selection-projection.ts）：`model/selection` 事件
// 表达"下一次请求要用什么"，`request/header` 记录"上一次请求实际用了什么"，
// 有效值 = pending ?? lastUsed。两者都是会话内的观察事实，可以核对，不是推断。
//
// 这条依据的用处：客户端只给了模型 id、没给 provider 时，如果这个模型正是会话当前在用的
// 那个，那么它用的 provider 就是唯一正确的答案——不需要再去目录里挑。
// 记录不在缓存里（例如更早的轮次已被切掉）时返回 false，由调用方继续走目录。
func deepSeekSessionSelection(records []harnessclient.SessionWireEvent) (deepSeekSelection, bool) {
	var lastUsed *deepSeekSelection
	var pending *deepSeekSelection
	for _, record := range records {
		switch record.Type {
		case deepSeekEventModelSelection:
			var data deepSeekModelSelectionData
			if json.Unmarshal(record.Data, &data) != nil {
				continue
			}
			selection := deepSeekSelection{
				Provider: strings.TrimSpace(data.Provider),
				Model:    strings.TrimSpace(data.Model),
				Effort:   strings.TrimSpace(data.ReasoningEffort),
			}
			if selection.Provider != "" && selection.Model != "" {
				// 后一条 model/selection 会替换前一条 pending，不能在第一次命中时返回。
				pending = &selection
			}
		case deepSeekEventRequestHeader:
			var data struct {
				Header struct {
					Config struct {
						Provider        string          `json:"provider"`
						Model           string          `json:"model"`
						ReasoningEffort json.RawMessage `json:"reasoningEffort"`
					} `json:"config"`
				} `json:"header"`
			}
			if json.Unmarshal(record.Data, &data) != nil {
				continue
			}
			config := data.Header.Config
			selection := deepSeekSelection{
				Provider: strings.TrimSpace(config.Provider),
				Model:    strings.TrimSpace(config.Model),
			}
			// Harness 的投影用 String(...) 规范化实际档位；保留该字段才能准确判断
			// pending 是否已被这次请求消费。字段缺失时与未指定档位等价。
			if len(config.ReasoningEffort) > 0 && string(config.ReasoningEffort) != "null" {
				var effort any
				if json.Unmarshal(config.ReasoningEffort, &effort) == nil {
					selection.Effort = strings.TrimSpace(fmt.Sprint(effort))
				}
			}
			if selection.Provider == "" || selection.Model == "" {
				continue
			}
			lastUsed = &selection
			// Harness 只在实际使用的完整选择等于 pending 时消费它。否则 pending
			// 仍表示下一次请求的选择，优先级继续高于刚观察到的 lastUsed。
			if pending != nil && *pending == selection {
				pending = nil
			}
		}
	}
	if pending != nil {
		return *pending, true
	}
	if lastUsed != nil && lastUsed.Provider != "" && lastUsed.Model != "" {
		return *lastUsed, true
	}
	return deepSeekSelection{}, false
}

// deepSeekCatalogEffort 决定把哪个推理档位交给 Harness。
//
// 三种情况必须分开处理，因为它们的真相不同：
//
//   - 该模型声明了档位，且请求的档位在其中：用目录里的 canonical id 下发。与移动端
//     "命中目录后使用服务端返回值"是同一口径，避免旧草稿里的别名被直接送进上游。
//   - 该模型声明了档位，但请求的不在其中：拒绝并列出可选档位。静默换成另一个档位，
//     用户会以为"高推理"已经生效。
//   - 该模型没有声明任何档位：不下发档位。这类模型没有推理强度可调，客户端带上来的
//     值无处可落；递一个上游不认识的参数只会让整次发送失败，而它本来没有任何东西需要
//     被兑现。留一条诊断，现场能看出档位没有下发及原因。
func deepSeekCatalogEffort(model harnessclient.ModelEntry, requested string) (string, error) {
	requested = strings.TrimSpace(requested)
	var declared []harnessclient.ModelReasoningEffort
	if model.Reasoning != nil {
		declared = model.Reasoning.Efforts
	}
	if len(declared) == 0 {
		if requested != "" {
			log.Printf("deepseek gateway 模型未声明推理档位，已忽略请求的档位 model=%s",
				sanitizeGatewayDiagnostic(model.ID))
		}
		return "", nil
	}
	if requested == "" {
		// 客户端没有要求档位：交给 Harness 用它自己的默认值，不替它挑一个。
		return "", nil
	}
	available := make([]string, 0, len(declared))
	for _, effort := range declared {
		id := strings.TrimSpace(effort.ID)
		if id == "" {
			continue
		}
		if strings.EqualFold(id, requested) {
			return id, nil
		}
		available = append(available, id)
	}
	if len(available) == 0 {
		// 目录里全是空档位 id：无法证明请求的档位存在，按不支持处理。
		return "", &deepSeekModelSelectionError{message: fmt.Sprintf(
			"模型 %s 没有可用的推理档位", model.ID)}
	}
	return "", &deepSeekModelSelectionError{message: fmt.Sprintf(
		"模型 %s 不支持推理档位 %s，可用档位：%s",
		model.ID, requested, strings.Join(available, "、"))}
}

// applyDeepSeekModelSelection 把本次 turn/start 声明的模型与推理档位落到 Harness 会话上。
//
// 必须在 session/prompt 之前调用：选择是"下一轮用哪个模型"，prompt 之后再改只会作用到
// 再下一轮，而客户端拿到的却是这一轮的 turn id。
//
// 只在 turn/start 上落地选择：model 本身不过 thread/start 的参数边界（那里只放行
// cwd/serviceTier/personality/modelProvider），因此新会话的模型仍然在这条会话的第一次
// turn/start 上落下。modelProvider 是例外——iOS 端把它放在 thread/start 上，而它是
// 同名模型下选对供应商的依据，所以那条字段能过来并在 threadProviders 里记住。
//
// 刻意不缓存"上次已经选过同一个模型"来省掉这两次调用。Harness 的会话选择不是本连接独占
// 的状态（Harness Web 页面同样能改），靠本地单例推断出的一致会在这个连接不知情时失效，
// 而失效的表现恰好是"用户改了模型但这一轮用了上一个"——与不做选择是同一种错。
// 每次按请求下发是幂等的，代价只是一次目录读取与一次选择。
func (c *deepSeekGatewayConn) applyDeepSeekModelSelection(
	ctx context.Context,
	threadID string,
	params map[string]any,
) error {
	requested := deepSeekTurnSelectionParams(params)
	if requested.Model == "" {
		if requested.Effort == "" {
			// 客户端没有表达任何选择：沿用 Harness 会话当前的选择。
			return nil
		}
		// 只给了档位：selectModel 必须带 provider+model 才能表达一次选择，缺了模型就
		// 无法把它落到会话上。拒绝而不是忽略。
		return &deepSeekModelSelectionError{
			message: "只给了推理档位、没有给模型，无法确定要改动哪个模型的选择",
		}
	}

	catalog, err := c.harness.ModelCatalog(ctx)
	if err != nil {
		log.Printf("deepseek gateway 读取模型目录失败 err=%v", sanitizeGatewayDiagnostic(err.Error()))
		return errors.New("deepseek gateway: 读取 Harness 模型目录失败")
	}
	match, err := c.resolveDeepSeekModel(catalog, threadID, requested)
	if err != nil {
		return err
	}
	effort, err := deepSeekCatalogEffort(match.Model, requested.Effort)
	if err != nil {
		return err
	}

	if err := c.harness.SelectModel(ctx, harnessclient.SelectModelRequest{
		SessionID:       threadID,
		Provider:        match.Provider,
		Model:           match.Model.ID,
		ReasoningEffort: effort,
	}); err != nil {
		var remote *harnessclient.RemoteError
		if errors.As(err, &remote) {
			// Harness 明确否决了这次选择：用户能据此重选，所以给可操作的原因，
			// 但仍不带上游错误原文。
			log.Printf("deepseek gateway 模型选择被 Harness 拒绝 code=%s",
				sanitizeGatewayDiagnostic(remote.Code))
			return &deepSeekModelSelectionError{message: fmt.Sprintf(
				"Harness 不接受模型 %s 的选择，请重新选择模型", match.Model.ID)}
		}
		log.Printf("deepseek gateway 转发模型选择失败 err=%v", sanitizeGatewayDiagnostic(err.Error()))
		return errors.New("deepseek gateway: 转发模型选择失败")
	}
	return nil
}

// resolveDeepSeekModel 决定一次模型选择落在哪个 provider 的哪个条目上。
//
// provider 是 session/selectModel 的必填项，而客户端可能只给模型 id。判据按证据强度
// 排序，每一层都是可核对的事实；都给不出结论时拒绝，绝不"取第一个"或"猜一个供应商"：
//
//  1. 本次请求声明的 provider。逐请求、最直接。它指不到这个模型就拒绝——用户明确指定了
//     供应商，换一个顶上正是要避免的"界面选 A、实际跑 B"。
//  2. 会话自己的持久选择（model/selection、request/header）。模型 id 与本次要求一致时，
//     会话当前用的 provider 就是唯一正确答案。这是观察事实。
//  3. 会话创建时客户端声明的 provider（thread/start 上的 modelProvider）。
//  4. 目录里唯一命中。多个 provider 都声明同一个 id 时拒绝并列出候选，不做选择——
//     模型目录按 provider 逐个列举，没有任何机制保证 model id 全局唯一，选错就是选错
//     供应商与计费路线。
func (c *deepSeekGatewayConn) resolveDeepSeekModel(
	catalog harnessclient.ModelCatalogResult,
	threadID string,
	requested deepSeekRequestedSelection,
) (deepSeekCatalogMatch, error) {
	if requested.Provider != "" {
		match, providers, ok := deepSeekCatalogLookup(catalog, requested.Model, requested.Provider)
		if !ok || len(providers) == 0 {
			return deepSeekCatalogMatch{}, &deepSeekModelSelectionError{message: fmt.Sprintf(
				"供应商 %s 没有声明模型 %s，请重新选择模型", requested.Provider, requested.Model)}
		}
		return match, nil
	}
	if follow, ok := c.followFor(threadID); ok {
		if selection, ok := deepSeekSessionSelection(follow.snapshot()); ok &&
			strings.EqualFold(selection.Model, requested.Model) {
			if match, _, found := deepSeekCatalogLookup(catalog, requested.Model, selection.Provider); found {
				return match, nil
			}
		}
	}
	if remembered := c.deepSeekThreadProvider(threadID); remembered != "" {
		if match, _, ok := deepSeekCatalogLookup(catalog, requested.Model, remembered); ok {
			return match, nil
		}
	}
	match, candidates, ok := deepSeekCatalogLookup(catalog, requested.Model, "")
	if ok {
		return match, nil
	}
	if len(candidates) > 1 {
		return deepSeekCatalogMatch{}, &deepSeekModelSelectionError{message: fmt.Sprintf(
			"模型 %s 在多个供应商下存在（%s），请先选定供应商再发送",
			requested.Model, strings.Join(candidates, "、"))}
	}
	return deepSeekCatalogMatch{}, &deepSeekModelSelectionError{message: fmt.Sprintf(
		"Harness 模型目录里没有模型 %s，请重新选择模型", requested.Model)}
}

// rememberDeepSeekThreadProvider 记住客户端在 thread/start 上声明的供应商。
//
// 只在新建会话时记录：iOS 端只在 thread/start 上带 modelProvider，而后续每条 turn/start
// 只带 model。不记住它的话，"同名模型出现在多个 provider 下"时就没有客户端依据可用。
func (c *deepSeekGatewayConn) rememberDeepSeekThreadProvider(threadID string, params map[string]any) {
	provider, ok := gatewayStringParam(params, "modelProvider")
	if !ok {
		return
	}
	provider = strings.TrimSpace(provider)
	if provider == "" || strings.TrimSpace(threadID) == "" {
		return
	}
	c.mu.Lock()
	if c.threadProviders == nil {
		c.threadProviders = map[string]string{}
	}
	c.threadProviders[threadID] = provider
	c.mu.Unlock()
}

// deepSeekThreadProvider 返回会话创建时声明的供应商。
func (c *deepSeekGatewayConn) deepSeekThreadProvider(threadID string) string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.threadProviders[threadID]
}

package httpapi

import (
	"context"
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
// providerHint 给了就按它取分组，指不到就返回 false——同一个 id 可能出现在多个 provider 下，
// 客户端明确说了用哪一个却落到另一个，是"界面选 A、实际跑 B"的另一种形态，不能靠"第一个
// 命中项"糊过去。没给提示（Mimi 的 iOS 端把 provider 放在 thread/start 上）才取第一个命中项。
func deepSeekCatalogLookup(
	catalog harnessclient.ModelCatalogResult,
	modelID string,
	providerHint string,
) (deepSeekCatalogMatch, bool) {
	modelID = strings.TrimSpace(modelID)
	if modelID == "" {
		return deepSeekCatalogMatch{}, false
	}
	providerHint = strings.TrimSpace(providerHint)
	var fallback *deepSeekCatalogMatch
	for _, group := range catalog.Groups {
		if providerHint != "" && !strings.EqualFold(strings.TrimSpace(group.ID), providerHint) {
			continue
		}
		for _, model := range group.Models {
			if !strings.EqualFold(strings.TrimSpace(model.ID), modelID) {
				continue
			}
			match := deepSeekCatalogMatch{Provider: group.ID, Model: model}
			if providerHint != "" {
				return match, true
			}
			if fallback == nil {
				fallback = &match
			}
		}
	}
	if fallback == nil {
		return deepSeekCatalogMatch{}, false
	}
	return *fallback, true
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
// 只在 turn/start 上处理，不需要在 thread/start 上再做一次：policy 的
// sanitizedGatewayThreadParams 不把 model/modelProvider 带过运行时边界，适配层根本看不到
// 它们，因此那里不存在"声明了却被丢掉"的情况。带输入的新会话由客户端把 thread/start 与
// 首条 turn/start 一起发；空会话则在这条会话的第一次 turn/start 上把选择落下，用户看到的
// 选择与实际执行的模型仍是一致的。
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
	match, ok := deepSeekCatalogLookup(catalog, requested.Model, requested.Provider)
	if !ok {
		return &deepSeekModelSelectionError{message: fmt.Sprintf(
			"Harness 模型目录里没有模型 %s，请重新选择模型", requested.Model)}
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

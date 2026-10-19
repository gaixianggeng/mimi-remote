package httpapi

import (
	"context"
	"encoding/json"
	"log"
	"strings"
	"sync"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
	"github.com/gaixianggeng/mimi-remote/internal/pushbridge"
)

// DeepSeek 回复提醒（#568）。
//
// Codex 与 Claude 的回复提醒由 app-server 网关在转发上游帧时产生。DeepSeek 走原生
// Harness 中继，agentd 只在手机持有 /api/harness/ws 订阅时才看得到会话事件，而 App
// 一进后台或锁屏，这条连接就断了。所以这里不依赖手机连接：手机经 agentd 提交
// session/prompt 时，agentd 自己对该会话开一条只读 session/follow，只看两类 durable
// 记录——带本次 requestId 的 user/message 与其后的 turn/end——回合结束时投递一次
// 提醒，然后退订。
//
// 只观察经 Mimi 提交的回合：电脑端或其它客户端发起的回合不在这里推送。投递复用
// pushbridge 的消息入口，通知开关、设备能力、定位记录与跨重启去重都与 Codex 一致。

const (
	// 每个会话至多一条观察订阅；全局上限防止批量提交把本机到 Harness 的连接数打满。
	harnessTurnPushMaxWatchers = 16
	// 观察订阅的最长寿命。超出仍未结束的回合不再提醒，已被丢弃的提交不会永远占着连接。
	harnessTurnPushMaxLifetime = 6 * time.Hour
	harnessTurnPushOpenTimeout = 15 * time.Second
	// 开场快照只需覆盖刚提交的那条消息，不要 assistantStream，也不取长历史。
	harnessTurnPushSnapshotMessages = 20
)

// harnessTurnPushWatchers 拥有全部观察订阅。零值可用。
type harnessTurnPushWatchers struct {
	mu       sync.Mutex
	closing  bool
	watchers map[string]*harnessTurnPushWatcher
	wg       sync.WaitGroup
}

// harnessTurnPushWatcher 的可变字段都由 harnessTurnPushWatchers.mu 保护：登记新提交与
// 判定“可以退订”必须在同一把锁里，否则刚登记的提交可能落进一条正在退出的订阅。
type harnessTurnPushWatcher struct {
	sessionID string
	cancel    context.CancelFunc
	// pending 是已登记、还没在 durable 日志里出现 user/message 的 requestId。
	pending map[string]struct{}
	// armed 表示当前回合含有经 Mimi 提交的消息，回合结束时需要提醒。
	armed bool
}

// harnessTurnPushRecord 是 durable 记录的外壳。data 保持原样，只对 user/message 与
// turn/end 按需取字段：其它事件的 data 形状各异，不能因为一条认不出的记录丢掉整页快照。
type harnessTurnPushRecord struct {
	Type  string `json:"type"`
	Event struct {
		Type string          `json:"type"`
		Seq  json.RawMessage `json:"seq"`
		Data json.RawMessage `json:"data"`
	} `json:"event"`
}

func decodeHarnessTurnPushRecord(raw json.RawMessage) (harnessTurnPushRecord, bool) {
	var record harnessTurnPushRecord
	if json.Unmarshal(raw, &record) != nil || record.Type != harnessclient.FrameDurableEvent {
		return harnessTurnPushRecord{}, false
	}
	return record, true
}

// requestID 取 user/message 的 source.rpcId，即提交时的 requestId；正文不解码。
func (record harnessTurnPushRecord) requestID() string {
	var data struct {
		Source struct {
			RPCID string `json:"rpcId"`
		} `json:"source"`
	}
	if json.Unmarshal(record.Event.Data, &data) != nil {
		return ""
	}
	return strings.TrimSpace(data.Source.RPCID)
}

// turnEnd 返回 turn/end 的去重身份与提醒事件。身份优先用 Harness 的回合序号，
// 缺失时退回日志 seq；两者都没有就无法去重，不提醒。
func (record harnessTurnPushRecord) turnEnd() (messageID string, event string) {
	var data struct {
		Turn   json.RawMessage `json:"turn"`
		Reason json.RawMessage `json:"reason"`
	}
	_ = json.Unmarshal(record.Event.Data, &data)
	if turn, ok := harnessTurnPushInteger(data.Turn); ok {
		messageID = "turn:" + turn
	} else if seq, ok := harnessTurnPushInteger(record.Event.Seq); ok {
		messageID = "seq:" + seq
	}
	var reason struct {
		Kind string `json:"kind"`
	}
	_ = json.Unmarshal(data.Reason, &reason)
	return messageID, harnessTurnPushEvent(reason.Kind)
}

func harnessTurnPushInteger(raw json.RawMessage) (string, bool) {
	var value json.Number
	if json.Unmarshal(raw, &value) != nil {
		return "", false
	}
	if integer, err := value.Int64(); err != nil || integer < 0 {
		return "", false
	}
	return value.String(), true
}

// beginHarnessTurnPush 在转发 session/prompt 之前登记这次提交，返回的 finish 以
// “提交是否可能已被上游接受”调用。未启用推送时什么都不做。
func (r *Router) beginHarnessTurnPush(sessionID string, requestID string) func(accepted bool) {
	noop := func(bool) {}
	sessionID = strings.TrimSpace(sessionID)
	requestID = strings.TrimSpace(requestID)
	if !r.pushEnabled() || sessionID == "" || requestID == "" {
		return noop
	}
	watchers := &r.harnessTurnPush
	watchers.mu.Lock()
	defer watchers.mu.Unlock()
	if watchers.closing {
		return noop
	}
	watcher := watchers.watchers[sessionID]
	if watcher == nil {
		if len(watchers.watchers) >= harnessTurnPushMaxWatchers {
			log.Printf("deepseek 回复提醒观察数已达上限，本次提交不提醒 limit=%d", harnessTurnPushMaxWatchers)
			return noop
		}
		ctx, cancel := context.WithTimeout(context.Background(), harnessTurnPushMaxLifetime)
		watcher = &harnessTurnPushWatcher{sessionID: sessionID, cancel: cancel, pending: map[string]struct{}{}}
		if watchers.watchers == nil {
			watchers.watchers = map[string]*harnessTurnPushWatcher{}
		}
		watchers.watchers[sessionID] = watcher
		watchers.wg.Add(1)
		go func() {
			defer watchers.wg.Done()
			defer cancel()
			defer watchers.forget(watcher)
			r.runHarnessTurnPushWatcher(ctx, watcher)
		}()
	}
	watcher.pending[requestID] = struct{}{}
	return func(accepted bool) {
		if !accepted {
			watchers.withdraw(watcher, requestID)
		}
	}
}

// withdraw 撤回一次被上游明确拒绝的提交；订阅上再没有要等的回合时立即退订。
func (watchers *harnessTurnPushWatchers) withdraw(watcher *harnessTurnPushWatcher, requestID string) {
	watchers.mu.Lock()
	defer watchers.mu.Unlock()
	delete(watcher.pending, requestID)
	if watcher.armed || len(watcher.pending) > 0 {
		return
	}
	if watchers.watchers[watcher.sessionID] == watcher {
		delete(watchers.watchers, watcher.sessionID)
	}
	watcher.cancel()
}

func (watchers *harnessTurnPushWatchers) forget(watcher *harnessTurnPushWatcher) {
	watchers.mu.Lock()
	defer watchers.mu.Unlock()
	if watchers.watchers[watcher.sessionID] == watcher {
		delete(watchers.watchers, watcher.sessionID)
	}
}

// shutdown 拒绝新的登记并等待全部观察订阅退出；必须早于 push.Close，
// 否则退出途中的最后一次投递会被丢弃。
func (watchers *harnessTurnPushWatchers) shutdown() {
	watchers.mu.Lock()
	watchers.closing = true
	for _, watcher := range watchers.watchers {
		watcher.cancel()
	}
	watchers.watchers = nil
	watchers.mu.Unlock()
	watchers.wg.Wait()
}

// observe 把一条 durable 记录应用到观察状态上。deliver 为 true 时返回待投递的消息；
// done 为 true 时订阅已从登记表摘除，调用方应退订。
func (watchers *harnessTurnPushWatchers) observe(
	watcher *harnessTurnPushWatcher,
	record harnessTurnPushRecord,
) (message pushbridge.Message, deliver bool, done bool) {
	var requestID, messageID, event string
	switch record.Event.Type {
	case "user/message":
		requestID = record.requestID()
	case "turn/end":
		messageID, event = record.turnEnd()
	default:
		return pushbridge.Message{}, false, false
	}
	watchers.mu.Lock()
	defer watchers.mu.Unlock()
	switch record.Event.Type {
	case "user/message":
		if _, ok := watcher.pending[requestID]; ok && requestID != "" {
			delete(watcher.pending, requestID)
			watcher.armed = true
		}
		return pushbridge.Message{}, false, false
	case "turn/end":
		if !watcher.armed || messageID == "" {
			// 不含 Mimi 提交的回合（例如提交之前电脑端正在跑的那一轮）不提醒。
			return pushbridge.Message{}, false, false
		}
		watcher.armed = false
		message = pushbridge.Message{
			Runtime:   pushbridge.RuntimeDeepSeek,
			ThreadID:  watcher.sessionID,
			MessageID: messageID,
			Event:     event,
		}
		if len(watcher.pending) == 0 {
			if watchers.watchers[watcher.sessionID] == watcher {
				delete(watchers.watchers, watcher.sessionID)
			}
			return message, true, true
		}
		return message, true, false
	}
	return pushbridge.Message{}, false, false
}

// harnessTurnPushEvent 映射 turn/end 的 reason.kind。契约只承诺 completed 与非 completed，
// 用户取消实测为 aborted；其余非 completed 都按失败提醒，不把异常结束说成“已回复”。
func harnessTurnPushEvent(kind string) string {
	switch strings.TrimSpace(kind) {
	case "", "completed":
		return pushbridge.EventTurnCompleted
	case "aborted":
		return pushbridge.EventTurnInterrupted
	default:
		return pushbridge.EventTurnFailed
	}
}

// runHarnessTurnPushWatcher 打开只读 follow，先回放开场快照再消费增量事件。任何一步
// 失败都只记一行脱敏日志后退出：提醒丢一条不能影响会话本身。
func (r *Router) runHarnessTurnPushWatcher(ctx context.Context, watcher *harnessTurnPushWatcher) {
	openCtx, cancelOpen := context.WithTimeout(ctx, harnessTurnPushOpenTimeout)
	client, err := r.harnessNativeClientFor(openCtx)
	if err != nil {
		cancelOpen()
		log.Printf("deepseek 回复提醒无法连接 Harness err=%s", sanitizeGatewayDiagnostic(err.Error()))
		return
	}
	stream, err := client.OpenStream(openCtx, harnessclient.MethodSessionFollow, map[string]any{
		"request": map[string]any{
			"address":     map[string]any{"kind": "session", "sessionId": watcher.sessionID},
			"maxMessages": harnessTurnPushSnapshotMessages,
		},
	})
	cancelOpen()
	if err != nil {
		log.Printf("deepseek 回复提醒无法订阅会话 err=%s", sanitizeGatewayDiagnostic(err.Error()))
		return
	}
	defer stream.Close()

	var route threadRouteFacts
	awaitingSnapshot := true
	for {
		select {
		case <-ctx.Done():
			return
		case frame, ok := <-stream.Frames():
			if !ok {
				log.Printf("deepseek 回复提醒订阅已断开")
				return
			}
			if _, failed := frame.CarrierFailure(); failed || frame.IsCarrierEnd() {
				log.Printf("deepseek 回复提醒订阅被上游结束")
				return
			}
			if awaitingSnapshot {
				records, facts, ok := r.harnessTurnPushSnapshot(watcher.sessionID, frame)
				if !ok {
					return
				}
				route = facts
				awaitingSnapshot = false
				for _, raw := range records {
					record, ok := decodeHarnessTurnPushRecord(raw)
					if ok && r.applyHarnessTurnPushRecord(watcher, route, record) {
						return
					}
				}
				continue
			}
			record, ok := decodeHarnessTurnPushRecord(frame.Raw)
			if !ok {
				continue
			}
			if r.applyHarnessTurnPushRecord(watcher, route, record) {
				return
			}
		}
	}
}

// harnessTurnPushSnapshot 校验开场快照的归属与目录，并取出其中的 durable 记录。
// 与手机侧 follow 同一条授权边界：会话 cwd 不在授权范围内就不推送。
func (r *Router) harnessTurnPushSnapshot(
	sessionID string,
	frame harnessclient.StreamValue,
) ([]json.RawMessage, threadRouteFacts, bool) {
	if frame.Type != harnessclient.FrameSnapshot {
		log.Printf("deepseek 回复提醒首帧不是 snapshot")
		return nil, threadRouteFacts{}, false
	}
	var snapshot struct {
		Header struct {
			ID  string `json:"id"`
			CWD string `json:"cwd"`
		} `json:"header"`
		Records []json.RawMessage `json:"records"`
	}
	if json.Unmarshal(frame.Raw, &snapshot) != nil || strings.TrimSpace(snapshot.Header.ID) != sessionID {
		log.Printf("deepseek 回复提醒快照归属不一致")
		return nil, threadRouteFacts{}, false
	}
	cwd := strings.TrimSpace(snapshot.Header.CWD)
	scope, ok := r.gatewayScopeForPath(cwd)
	if cwd == "" || !ok {
		log.Printf("deepseek 回复提醒会话目录不在授权范围内")
		return nil, threadRouteFacts{}, false
	}
	facts := threadRouteFacts{
		runtime:   pushbridge.RuntimeDeepSeek,
		cwd:       cwd,
		scopeID:   scope.id,
		projectID: scope.id,
	}
	if facts.projectID == "" {
		if project, ok := r.projectForGatewayPath(cwd); ok {
			facts.projectID = project.ID
		}
	}
	return snapshot.Records, facts, true
}

// applyHarnessTurnPushRecord 返回 true 表示订阅已完成使命，应当退订。
func (r *Router) applyHarnessTurnPushRecord(
	watcher *harnessTurnPushWatcher,
	route threadRouteFacts,
	record harnessTurnPushRecord,
) bool {
	message, deliver, done := r.harnessTurnPush.observe(watcher, record)
	if deliver {
		message.ProjectID = route.projectID
		message.ScopeID = route.scopeID
		message.CWD = route.cwd
		if delivery := r.push.PrepareMessage(message); delivery != nil {
			r.push.Dispatch(delivery, pushDecideTimeout)
		}
	}
	return done
}

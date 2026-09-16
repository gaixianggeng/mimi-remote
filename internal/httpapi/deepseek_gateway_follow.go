package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

// 本文件维护一条会话订阅（session/follow）的本地状态。
//
// 订阅同时承担两件事，因此不能按需临时开：
//
//   - 开场 snapshot 给出的 cursor 是 session/page 的必填 throughSeq，没有它连历史读不了。
//   - 实时的 turn 与 assistant-stream 帧只在这条订阅上出现，直播正文依赖它。
//
// 记录缓存按 seq 去重并保持升序。分页读到的页会并入缓存，这样同一 turn 的 items 请求
// 不必重复向 Harness 取同一段记录。

// deepSeekFollow 是一条会话订阅及其记录缓存。
type deepSeekFollow struct {
	threadID string
	stream   *harnessclient.Stream

	mu sync.Mutex
	// throughSeq 是订阅开场时 Harness 给出的日志切点。分页必须停在这里，
	// 否则会读到订阅开始之后、尚未经事件流下发的记录，直播与历史就会同时出现。
	throughSeq int64
	// records 按 seq 升序，去重。
	records []harnessclient.SessionWireEvent
	// reachedStart 表示已经读到会话最早一条记录；为 true 时不再继续向前分页。
	reachedStart bool
	// attempts 记住直播片段所属的 (turn, step)。
	//
	// assistant-stream 只有 start 帧带 turn/step，chunk 帧不带。增量必须落到与持久
	// assistant/message 相同的 (turn, step) 上，否则同一条消息在直播间与历史回读会
	// 得到两个 item id，Mimi 原位覆盖失效并显示重复气泡。
	attempts map[string]deepSeekStreamAttempt
	// updated 在缓存并入新记录后发一个信号，供等待"本次投递对应的 turn"的请求唤醒。
	// 带缓冲且非阻塞：没有人在等的时候信号必须能丢掉，否则会阻塞事件读协程。
	updated chan struct{}
}

// signalUpdated 通知等待者缓存又变了。非阻塞，调用方不必关心有没有人在等。
func (f *deepSeekFollow) signalUpdated() {
	select {
	case f.updated <- struct{}{}:
	default:
	}
}

// turnForRequest 返回到目前为止"本次投递"对应的 turn 编号。
//
// 判据是 user/message 的 source.rpcId —— 协议文档把它定为 prompt 的 requestId，
// Harness 自己也用它做消息去重。turn 号不在 user/message 上（实测只有 assistant/message
// 与 step/* 明确带 turn），所以按记录顺序把它归入所属的 turn 桶，取桶的 turn。
// 顺序切分沿用 deepSeekSplitTurns 的同一套口径，不引入第二种说法。
//
// 只认 requestId 相同的那条消息：别的会话、别的端、同会话里排队的前一次投递都拿不到，
// 因此不会出现"把别人的 turn 编号当成本次的"。
func (f *deepSeekFollow) turnForRequest(requestID string) (int64, bool) {
	if strings.TrimSpace(requestID) == "" {
		return 0, false
	}
	for _, bucket := range deepSeekSplitTurns(f.snapshot()) {
		for _, record := range bucket.Records {
			if record.Type != deepSeekEventUserMessage {
				continue
			}
			var data deepSeekMessageData
			if json.Unmarshal(record.Data, &data) != nil || data.Source == nil {
				continue
			}
			if data.Source.RPCID == requestID {
				return bucket.Turn, true
			}
		}
	}
	return 0, false
}

// awaitTurnForRequest 等到本次投递自己的 turn 出现。
//
// 超时或连接结束时返回 false，调用方必须按"拿不到 turn id"处理，不能退回到"等下一个
// 出现的 turn"：那会在多端或排队场景下把另一轮的编号回给客户端，而客户端的乐观消息绑定、
// 中断对账与 active 清理都以这个 id 为准。
func (f *deepSeekFollow) awaitTurnForRequest(
	ctx context.Context,
	requestID string,
	timeout time.Duration,
) (int64, bool) {
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	for {
		// 先查缓存再等信号：投递可能早在进入等待之前就已经落到日志里了。
		if turn, ok := f.turnForRequest(requestID); ok {
			return turn, true
		}
		select {
		case <-f.updated:
		case <-deadline.C:
			// 信号与超时可能同时就绪，超时前再看一眼缓存，避免丢掉已经到达的 turn。
			turn, ok := f.turnForRequest(requestID)
			return turn, ok
		case <-ctx.Done():
			return 0, false
		}
	}
}

// deepSeekStreamAttempt 是一次直播输出的定位。
type deepSeekStreamAttempt struct {
	Turn int64
	Step int64
}

// deepSeekStreamStart 记下一个直播片段的位置。
func (f *deepSeekFollow) noteAttempt(attemptID string, turn, step int64) {
	if strings.TrimSpace(attemptID) == "" {
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.attempts == nil {
		f.attempts = map[string]deepSeekStreamAttempt{}
	}
	f.attempts[attemptID] = deepSeekStreamAttempt{Turn: turn, Step: step}
}

// attempt 返回直播片段的位置。
func (f *deepSeekFollow) attempt(attemptID string) (deepSeekStreamAttempt, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	attempt, ok := f.attempts[attemptID]
	return attempt, ok
}

// forgetAttempt 在片段结束后释放位置记录。
func (f *deepSeekFollow) forgetAttempt(attemptID string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.attempts, attemptID)
}

// awaitSnapshot 等到开场快照并记录切点与尾部记录。
func (f *deepSeekFollow) awaitSnapshot(ctx context.Context) error {
	frame, err := f.stream.Until(ctx, "snapshot", deepSeekSnapshotTimeout, func(value harnessclient.StreamValue) bool {
		return value.Type == harnessclient.FrameSnapshot
	})
	if err != nil {
		return err
	}
	var snapshot harnessclient.FollowSnapshot
	if err := frame.Decode(&snapshot); err != nil {
		return err
	}
	records := make([]harnessclient.SessionWireEvent, 0, len(snapshot.Records))
	for _, record := range snapshot.Records {
		records = append(records, record.Wire())
	}
	f.mu.Lock()
	f.throughSeq = snapshot.Cursor
	f.noteLocked(records)
	// snapshot 明确说没有更早的记录时，才认定已经到开头。hasMore 为 false 但记录为空
	// 同样是到开头。
	f.reachedStart = !snapshot.HasMore
	f.mu.Unlock()
	return nil
}

// through 返回分页切点。
func (f *deepSeekFollow) through() int64 {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.throughSeq
}

// hasSnapshot 报告切点是否已经就位。
func (f *deepSeekFollow) hasSnapshot() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.throughSeq > 0
}

// note 把新记录并入缓存，并唤醒等待本次投递对应 turn 的请求。
func (f *deepSeekFollow) note(records []harnessclient.SessionWireEvent) {
	f.mu.Lock()
	f.noteLocked(records)
	f.mu.Unlock()
	f.signalUpdated()
}

func (f *deepSeekFollow) noteLocked(records []harnessclient.SessionWireEvent) {
	known := make(map[int64]struct{}, len(f.records))
	for _, record := range f.records {
		known[record.Seq] = struct{}{}
	}
	added := false
	for _, record := range records {
		if strings.TrimSpace(record.Type) == "" {
			continue
		}
		if _, exists := known[record.Seq]; exists {
			continue
		}
		known[record.Seq] = struct{}{}
		f.records = append(f.records, record)
		added = true
	}
	if added {
		sort.Slice(f.records, func(i, j int) bool { return f.records[i].Seq < f.records[j].Seq })
	}
}

// snapshot 复制当前缓存，供切分 turn 使用。
func (f *deepSeekFollow) snapshot() []harnessclient.SessionWireEvent {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]harnessclient.SessionWireEvent(nil), f.records...)
}

// oldestCachedSeq 返回缓存里最小的 seq，零值表示缓存为空。
func (f *deepSeekFollow) oldestCachedSeq() int64 {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.records) == 0 {
		return 0
	}
	return f.records[0].Seq
}

func (f *deepSeekFollow) markReachedStart() {
	f.mu.Lock()
	f.reachedStart = true
	f.mu.Unlock()
}

func (f *deepSeekFollow) atStart() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.reachedStart
}

// deepSeekTurnBucket 是一个 turn 及其记录。turn 与 step 在 Harness 里是数字，
// 因此这里保留数字并在翻译层合成字符串标识。
type deepSeekTurnBucket struct {
	Turn    int64
	Records []harnessclient.SessionWireEvent
	Ended   bool
	Reason  string
	// Started 表示本桶确实见到过这个 turn 的 turn/start。为 false 说明该轮的开头
	// 还在缓存边界之外——分页把它切掉了，于是桶里只剩一条 turn/end（或一条对不上的
	// turn/end）。这种桶的 Records 不是这一轮的完整记录，任何人都不能按"完整"处置它。
	Started bool
}

// deepSeekSplitTurns 按 turn/start 与 turn/end 的顺序把记录切成 turn。
//
// 刻意不依赖每条记录自带的 turn 字段：实测只有 assistant/message 与 step/* 明确带
// turn，user/message 不带。顺序切分对缺失字段免疫，也天然处理了事件被上游裁剪的情况。
func deepSeekSplitTurns(records []harnessclient.SessionWireEvent) []deepSeekTurnBucket {
	buckets := make([]deepSeekTurnBucket, 0, 4)
	var current *deepSeekTurnBucket
	for _, record := range records {
		switch record.Type {
		case deepSeekEventTurnStart:
			var data deepSeekTurnData
			if json.Unmarshal(record.Data, &data) != nil {
				continue
			}
			// 上一轮没有 turn/end 就遇到新的 turn/start（例如进程被中断），
			// 上一个桶自然收尾，不会把两轮的记录混在一起。
			buckets = append(buckets, deepSeekTurnBucket{Turn: data.Turn, Started: true})
			current = &buckets[len(buckets)-1]
			current.Records = append(current.Records, record)
		case deepSeekEventTurnEnd:
			var data deepSeekTurnData
			if json.Unmarshal(record.Data, &data) != nil {
				continue
			}
			if current == nil || current.Turn != data.Turn {
				// 没有见过的 turn 的结束事件：单独成一个只有结束的桶，
				// 保证状态能反映出来，而不是被静默丢弃。这个桶没有 turn/start，
				// 即 Started 保持 false——它的记录不完整，不能按完整处置。
				buckets = append(buckets, deepSeekTurnBucket{Turn: data.Turn, Ended: true})
				current = &buckets[len(buckets)-1]
			} else {
				current.Ended = true
			}
			if data.Reason != nil {
				current.Reason = data.Reason.Kind
			}
			current.Records = append(current.Records, record)
		default:
			if current == nil {
				continue
			}
			current.Records = append(current.Records, record)
		}
	}
	return buckets
}

// deepSeekTurnByNumber 在记录里找到指定 turn。
func deepSeekTurnByNumber(records []harnessclient.SessionWireEvent, turn int64) (deepSeekTurnBucket, bool) {
	for _, bucket := range deepSeekSplitTurns(records) {
		if bucket.Turn == turn {
			return bucket, true
		}
	}
	return deepSeekTurnBucket{}, false
}

// errDeepSeekThreadUnknown 表示请求指向的会话不在授权范围内或不存在。
var errDeepSeekThreadUnknown = errors.New("deepseek gateway: 会话不存在")

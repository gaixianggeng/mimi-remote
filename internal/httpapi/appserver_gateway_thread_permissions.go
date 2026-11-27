package httpapi

import (
	"bytes"
	"encoding/json"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

var appServerGatewayRestrictionFloorMax = 4096

func (p *appServerGatewayPolicy) now() time.Time {
	if p != nil && p.nowFunc != nil {
		return p.nowFunc()
	}
	return time.Now()
}

func (p *appServerGatewayPolicy) activeSinkGen() uint64 {
	if p == nil || p.currentSinkGen == nil {
		return 0
	}
	return p.currentSinkGen()
}

func normalizeAllowedThreadRestrictionBits(t appServerGatewayAllowedThread) appServerGatewayAllowedThread {
	if t.readOnlySubagent || t.readOnlyBrowseScope || (t.readOnly && !t.cwdMissing) {
		t.readOnlyPermanent = true
	}
	if !t.cwdMissing && !t.readOnly && t.directInputKnown && !t.canAcceptDirectInput {
		t.explicitDirectInputDenied = true
	}
	t.readOnly = t.readOnlyPermanent || t.cwdMissing
	if t.readOnly || t.explicitDirectInputDenied {
		t.directInputKnown = true
		t.canAcceptDirectInput = false
	}
	return t
}

// buildAllowedThreadFromWire 从单条上游线程载荷构造正交权限记录（先于 forceReadOnly 压扁）：
// 区分结构性只读（readOnlyPermanent）、瞬态缺失（cwdMissing）与独立显式禁写（explicitDirectInputDenied）；
// 对 Agy 同帧 cwdMissing:true 且无 claudeOwner 的情况，即使目录在阶段 A 前已恢复也不误固化为 explicitDirectInputDenied。
func buildAllowedThreadFromWire(
	id string,
	runtimeID string,
	cwd string,
	scopeID string,
	itemFields map[string]json.RawMessage,
	wire appServerGatewayThreadWire,
	isSubagent bool,
	readOnlyBrowseScope bool,
	scopeMissing bool,
	autoTitleEligible bool,
) appServerGatewayAllowedThread {
	readOnlyPermanent := isSubagent || readOnlyBrowseScope
	wireMissing := wire.CWDMissing != nil && *wire.CWDMissing
	effectiveMissing := scopeMissing || wireMissing
	hasExternalOwner := false
	if rawOwner, exists := itemFields["claudeOwner"]; exists {
		trimmed := bytes.TrimSpace(rawOwner)
		if len(trimmed) > 0 && !bytes.Equal(trimmed, []byte("null")) {
			hasExternalOwner = true
		}
	}

	rawInput := rawDirectInputUnknown
	explicitDenied := false
	if wire.CanAcceptDirectInput != nil {
		if !*wire.CanAcceptDirectInput {
			if (!effectiveMissing && !readOnlyPermanent) || hasExternalOwner {
				explicitDenied = true
				rawInput = rawDirectInputDeny
			}
		} else if !effectiveMissing && !readOnlyPermanent {
			rawInput = rawDirectInputAllow
		}
	}

	readOnly := readOnlyPermanent || scopeMissing
	canAccept := false
	directKnown := readOnly || explicitDenied || rawInput == rawDirectInputAllow
	if !readOnly && !explicitDenied && rawInput == rawDirectInputAllow {
		canAccept = true
	}

	return appServerGatewayAllowedThread{
		id:                        strings.TrimSpace(id),
		runtimeID:                 normalizeAppServerRuntimeID(runtimeID),
		cwd:                       cwd,
		scopeID:                   scopeID,
		canAcceptDirectInput:      canAccept,
		directInputKnown:          directKnown,
		readOnly:                  readOnly,
		readOnlySubagent:          isSubagent,
		readOnlyBrowseScope:       readOnlyBrowseScope,
		readOnlyPermanent:         readOnlyPermanent,
		explicitDirectInputDenied: explicitDenied,
		rawDirectInput:            rawInput,
		cwdMissing:                scopeMissing,
		autoTitleEligible:         autoTitleEligible,
	}
}

// mergeSamePageAllowedThread 同页多条获准同 ID 候选（及 relatedThreads）的严格单调合并：
// 永不计算 pathRestored；全部限制来源做逻辑 OR，保证双顺序结果 100% 一致。
func mergeSamePageAllowedThread(a, b appServerGatewayAllowedThread) appServerGatewayAllowedThread {
	a = normalizeAllowedThreadRestrictionBits(a)
	b = normalizeAllowedThreadRestrictionBits(b)

	merged := b
	if strings.TrimSpace(merged.id) == "" {
		merged.id = a.id
	}
	if strings.TrimSpace(merged.runtimeID) == "" {
		merged.runtimeID = a.runtimeID
	}
	if strings.TrimSpace(merged.cwd) == "" {
		merged.cwd = a.cwd
	}
	if strings.TrimSpace(merged.scopeID) == "" {
		merged.scopeID = a.scopeID
	}
	merged.cwdMissing = a.cwdMissing || b.cwdMissing
	merged.readOnlySubagent = a.readOnlySubagent || b.readOnlySubagent
	merged.readOnlyBrowseScope = a.readOnlyBrowseScope || b.readOnlyBrowseScope
	merged.readOnlyPermanent = a.readOnlyPermanent || b.readOnlyPermanent || merged.readOnlySubagent || merged.readOnlyBrowseScope
	merged.explicitDirectInputDenied = a.explicitDirectInputDenied || b.explicitDirectInputDenied
	if a.explicitDirectInputVersion > merged.explicitDirectInputVersion {
		merged.explicitDirectInputVersion = a.explicitDirectInputVersion
	}
	if a.rawDirectInput == rawDirectInputDeny || b.rawDirectInput == rawDirectInputDeny {
		merged.rawDirectInput = rawDirectInputDeny
	} else if a.rawDirectInput == rawDirectInputAllow || b.rawDirectInput == rawDirectInputAllow {
		merged.rawDirectInput = rawDirectInputAllow
	} else {
		merged.rawDirectInput = rawDirectInputUnknown
	}
	merged.pushSeededOnly = a.pushSeededOnly && b.pushSeededOnly
	merged.readOnly = merged.readOnlyPermanent || merged.cwdMissing
	merged.autoTitleEligible = a.autoTitleEligible && b.autoTitleEligible
	if merged.readOnly || merged.explicitDirectInputDenied {
		merged.directInputKnown = true
		merged.canAcceptDirectInput = false
	} else if a.directInputKnown || b.directInputKnown {
		merged.directInputKnown = true
		merged.canAcceptDirectInput = a.canAcceptDirectInput && b.canAcceptDirectInput
		if !a.directInputKnown {
			merged.canAcceptDirectInput = b.canAcceptDirectInput
		} else if !b.directInputKnown {
			merged.canAcceptDirectInput = a.canAcceptDirectInput
		}
	} else {
		merged.directInputKnown = false
		merged.canAcceptDirectInput = false
	}
	return merged
}

// mergeHistoricalBaseline 合成连接级记录与全局缓存记录（及底板）为单一历史基线：
// 永久只读来源取 OR；explicitDirectInputDenied 按 explicitDirectInputVersion 较高者胜出（同版本保守 OR）。
func mergeHistoricalBaseline(connOld appServerGatewayAllowedThread, hasConn bool, globalOld appServerGatewayAllowedThread, hasGlobal bool) (appServerGatewayAllowedThread, bool) {
	if !hasConn && !hasGlobal {
		return appServerGatewayAllowedThread{}, false
	}
	if !hasConn {
		return normalizeAllowedThreadRestrictionBits(globalOld), true
	}
	if !hasGlobal {
		return normalizeAllowedThreadRestrictionBits(connOld), true
	}
	a := normalizeAllowedThreadRestrictionBits(connOld)
	b := normalizeAllowedThreadRestrictionBits(globalOld)

	base := b
	if strings.TrimSpace(base.id) == "" {
		base.id = a.id
	}
	if strings.TrimSpace(base.runtimeID) == "" {
		base.runtimeID = a.runtimeID
	}
	if strings.TrimSpace(base.cwd) == "" {
		base.cwd = a.cwd
	}
	if strings.TrimSpace(base.scopeID) == "" {
		base.scopeID = a.scopeID
	}
	base.cwdMissing = a.cwdMissing || b.cwdMissing
	base.readOnlySubagent = a.readOnlySubagent || b.readOnlySubagent
	base.readOnlyBrowseScope = a.readOnlyBrowseScope || b.readOnlyBrowseScope
	base.readOnlyPermanent = a.readOnlyPermanent || b.readOnlyPermanent || base.readOnlySubagent || base.readOnlyBrowseScope
	base.readOnly = base.readOnlyPermanent || base.cwdMissing
	base.pushSeededOnly = a.pushSeededOnly && b.pushSeededOnly
	base.autoTitleEligible = a.autoTitleEligible

	// 显式禁写按单调版本仲裁：较新版本胜出，防止连接 A 的旧 deny v1 覆盖连接 B 的新 allow v2，
	// 或连接 A 的旧 allow v1 绕过连接 B 的新 deny v2。
	switch {
	case a.explicitDirectInputVersion > b.explicitDirectInputVersion:
		base.explicitDirectInputDenied = a.explicitDirectInputDenied
		base.explicitDirectInputVersion = a.explicitDirectInputVersion
	case b.explicitDirectInputVersion > a.explicitDirectInputVersion:
		base.explicitDirectInputDenied = b.explicitDirectInputDenied
		base.explicitDirectInputVersion = b.explicitDirectInputVersion
	default:
		base.explicitDirectInputDenied = a.explicitDirectInputDenied || b.explicitDirectInputDenied
		base.explicitDirectInputVersion = a.explicitDirectInputVersion
	}

	if base.readOnly || base.explicitDirectInputDenied {
		base.directInputKnown = true
		base.canAcceptDirectInput = false
	} else if a.directInputKnown || b.directInputKnown {
		base.directInputKnown = true
		if a.explicitDirectInputVersion > b.explicitDirectInputVersion {
			base.canAcceptDirectInput = a.canAcceptDirectInput
		} else if b.explicitDirectInputVersion > a.explicitDirectInputVersion {
			base.canAcceptDirectInput = b.canAcceptDirectInput
		} else {
			base.canAcceptDirectInput = (!a.directInputKnown || a.canAcceptDirectInput) && (!b.directInputKnown || b.canAcceptDirectInput)
		}
	} else {
		base.directInputKnown = false
		base.canAcceptDirectInput = false
	}
	return base, true
}

// mergeCrossPageAllowedThread 用于 thread/list 阶段 B 将历史基线与本页已完整收敛的 pageMerged 合并：
// - pathRestored 仅解除历史瞬态 cwdMissing 只读，绝不清除 readOnlyPermanent 或 explicitDirectInputDenied；
// - 列表页不得凭自身 canAcceptDirectInput=true 放宽已有 explicitDirectInputDenied（仅 thread/read 可在空闲后恢复）。
func mergeCrossPageAllowedThread(historical, pageMerged appServerGatewayAllowedThread, allocVersion func() uint64) appServerGatewayAllowedThread {
	historical = normalizeAllowedThreadRestrictionBits(historical)
	pageMerged = normalizeAllowedThreadRestrictionBits(pageMerged)

	pathRestored := historical.cwdMissing && !pageMerged.cwdMissing
	pageMerged.readOnlySubagent = pageMerged.readOnlySubagent || historical.readOnlySubagent
	pageMerged.readOnlyBrowseScope = pageMerged.readOnlyBrowseScope || historical.readOnlyBrowseScope
	pageMerged.readOnlyPermanent = pageMerged.readOnlyPermanent || historical.readOnlyPermanent || pageMerged.readOnlySubagent || pageMerged.readOnlyBrowseScope
	if historical.cwdMissing && !pathRestored {
		pageMerged.cwdMissing = true
	}
	pageMerged.readOnly = pageMerged.readOnlyPermanent || pageMerged.cwdMissing
	// 真实列表响应到达，清除推送补种标记。
	pageMerged.pushSeededOnly = false

	// 版本与独立禁写：列表页只允许新增禁写或保留历史，绝不清除历史 explicitDirectInputDenied。
	pageMerged.explicitDirectInputVersion = historical.explicitDirectInputVersion
	if pageMerged.explicitDirectInputDenied || pageMerged.rawDirectInput == rawDirectInputDeny {
		pageMerged.explicitDirectInputDenied = true
		if allocVersion != nil {
			pageMerged.explicitDirectInputVersion = allocVersion()
		}
	} else if historical.explicitDirectInputDenied {
		pageMerged.explicitDirectInputDenied = true
	}

	if pageMerged.readOnly || pageMerged.explicitDirectInputDenied {
		pageMerged.directInputKnown = true
		pageMerged.canAcceptDirectInput = false
	} else if !pathRestored && !pageMerged.directInputKnown && historical.directInputKnown {
		pageMerged.directInputKnown = true
		pageMerged.canAcceptDirectInput = historical.canAcceptDirectInput
	}
	pageMerged.rawDirectInput = rawDirectInputUnknown
	return pageMerged
}

// mergeGatewayAllowedThreadWithVersion 用于非列表路径（thread/read / thread/start / thread/takeover / allowThread / push 补种）
// 在单快照下合并历史基线与本次原始更新：
// - 仅当本次原始入参显式声明 rawDirectInputAllow（且非只读）时才清除 explicitDirectInputDenied 并分配新版本（支持 C11）；
// - 省略 canAcceptDirectInput（rawDirectInputUnknown）时，即使 pathRestored 也继承历史 explicitDirectInputDenied 与版本。
func mergeGatewayAllowedThreadWithVersion(
	existing appServerGatewayAllowedThread,
	hasExisting bool,
	incoming appServerGatewayAllowedThread,
	allocVersion func() uint64,
) appServerGatewayAllowedThread {
	rawInput := incoming.rawDirectInput
	// 兼容未显式设置 rawDirectInput 的旧调用方（如测试直接构造 appServerGatewayAllowedThread）。
	if rawInput == rawDirectInputUnknown && incoming.directInputKnown && !incoming.cwdMissing && !incoming.readOnly {
		if incoming.canAcceptDirectInput {
			rawInput = rawDirectInputAllow
		} else {
			rawInput = rawDirectInputDeny
		}
	}
	incoming = normalizeAllowedThreadRestrictionBits(incoming)

	if !hasExisting {
		if rawInput == rawDirectInputDeny {
			incoming.explicitDirectInputDenied = true
			if allocVersion != nil {
				incoming.explicitDirectInputVersion = allocVersion()
			}
		} else if rawInput == rawDirectInputAllow && !incoming.readOnly {
			incoming.explicitDirectInputDenied = false
			if allocVersion != nil {
				incoming.explicitDirectInputVersion = allocVersion()
			}
		}
		incoming.rawDirectInput = rawDirectInputUnknown
		return incoming
	}

	existing = normalizeAllowedThreadRestrictionBits(existing)
	pathRestored := existing.cwdMissing && !incoming.cwdMissing
	incoming.readOnlySubagent = incoming.readOnlySubagent || existing.readOnlySubagent
	incoming.readOnlyBrowseScope = incoming.readOnlyBrowseScope || existing.readOnlyBrowseScope
	incoming.readOnlyPermanent = incoming.readOnlyPermanent || existing.readOnlyPermanent || incoming.readOnlySubagent || incoming.readOnlyBrowseScope
	if existing.cwdMissing && !pathRestored {
		incoming.cwdMissing = true
	}
	incoming.readOnly = incoming.readOnlyPermanent || incoming.cwdMissing

	// 推送补种不得降级已存在的真实运行时主表条目；真实运行时条目到达后清除 pushSeededOnly。
	if incoming.pushSeededOnly {
		incoming.pushSeededOnly = existing.pushSeededOnly
		if !existing.pushSeededOnly {
			// 保留已有真实主表的非只读字段与版本。
			incoming.explicitDirectInputDenied = existing.explicitDirectInputDenied
			incoming.explicitDirectInputVersion = existing.explicitDirectInputVersion
			if !incoming.readOnly && !incoming.explicitDirectInputDenied && existing.directInputKnown {
				incoming.directInputKnown = true
				incoming.canAcceptDirectInput = existing.canAcceptDirectInput
			}
			incoming.rawDirectInput = rawDirectInputUnknown
			return incoming
		}
	} else {
		incoming.pushSeededOnly = false
	}

	switch rawInput {
	case rawDirectInputDeny:
		incoming.explicitDirectInputDenied = true
		if allocVersion != nil {
			incoming.explicitDirectInputVersion = allocVersion()
		} else {
			incoming.explicitDirectInputVersion = existing.explicitDirectInputVersion
		}
	case rawDirectInputAllow:
		if !incoming.readOnly {
			incoming.explicitDirectInputDenied = false
			if allocVersion != nil {
				incoming.explicitDirectInputVersion = allocVersion()
			} else {
				incoming.explicitDirectInputVersion = existing.explicitDirectInputVersion
			}
		} else {
			incoming.explicitDirectInputDenied = existing.explicitDirectInputDenied
			incoming.explicitDirectInputVersion = existing.explicitDirectInputVersion
		}
	default:
		// 省略字段：即使目录恢复（pathRestored）也不清除历史独立禁写。
		incoming.explicitDirectInputDenied = incoming.explicitDirectInputDenied || existing.explicitDirectInputDenied
		incoming.explicitDirectInputVersion = existing.explicitDirectInputVersion
	}

	if incoming.readOnly || incoming.explicitDirectInputDenied {
		incoming.directInputKnown = true
		incoming.canAcceptDirectInput = false
	} else if rawInput == rawDirectInputAllow {
		incoming.directInputKnown = true
		incoming.canAcceptDirectInput = true
	} else if !pathRestored && !incoming.directInputKnown && existing.directInputKnown {
		incoming.directInputKnown = true
		incoming.canAcceptDirectInput = existing.canAcceptDirectInput
	}
	incoming.rawDirectInput = rawDirectInputUnknown
	return incoming
}

func allowedThreadBaselineEqual(a, b appServerGatewayAllowedThread) bool {
	return a.readOnly == b.readOnly &&
		a.readOnlyPermanent == b.readOnlyPermanent &&
		a.readOnlySubagent == b.readOnlySubagent &&
		a.readOnlyBrowseScope == b.readOnlyBrowseScope &&
		a.cwdMissing == b.cwdMissing &&
		a.explicitDirectInputDenied == b.explicitDirectInputDenied &&
		a.explicitDirectInputVersion == b.explicitDirectInputVersion &&
		a.directInputKnown == b.directInputKnown &&
		a.canAcceptDirectInput == b.canAcceptDirectInput &&
		a.pushSeededOnly == b.pushSeededOnly
}

// applyFloorToAllowedThread 将限制底板合并到主表条目（或构造仅含限制底板的虚拟历史记录）。
func applyFloorToAllowedThread(thread appServerGatewayAllowedThread, hasThread bool, floor gatewayThreadRestrictionFloor, hasFloor bool) (appServerGatewayAllowedThread, bool) {
	if !hasFloor {
		return thread, hasThread
	}
	floorEntry := appServerGatewayAllowedThread{
		id:                         thread.id,
		runtimeID:                  thread.runtimeID,
		cwd:                        thread.cwd,
		scopeID:                    thread.scopeID,
		readOnlyPermanent:          floor.readOnlyPermanent,
		readOnlySubagent:           floor.readOnlySubagent,
		readOnlyBrowseScope:        floor.readOnlyBrowseScope,
		readOnly:                   floor.readOnlyPermanent,
		explicitDirectInputDenied:  floor.explicitDirectInputDenied,
		explicitDirectInputVersion: floor.explicitDirectInputVersion,
		directInputKnown:           floor.readOnlyPermanent || floor.explicitDirectInputDenied,
		canAcceptDirectInput:       false,
	}
	if !hasThread {
		return floorEntry, true
	}
	merged, _ := mergeHistoricalBaseline(thread, true, floorEntry, true)
	merged.pushSeededOnly = thread.pushSeededOnly
	merged.cwd = thread.cwd
	merged.scopeID = thread.scopeID
	merged.lastSeen = thread.lastSeen
	return merged, true
}

// effectiveGatewayThreadLocked 要求调用方已持有 r.gatewayThreadsMu。
// 主表命中时也始终合并 r.gatewayThreadRestrictions 底板，主表缺失/淘汰时回退返回底板限制。
func (r *Router) effectiveGatewayThreadLocked(key string, now time.Time) (thread appServerGatewayAllowedThread, hasMain bool, hasAny bool) {
	if r == nil {
		return appServerGatewayAllowedThread{}, false, false
	}
	mainEntry, ok := r.gatewayThreads[key]
	if ok && gatewayThreadCacheExpired(mainEntry, now) {
		delete(r.gatewayThreads, key)
		ok = false
		mainEntry = appServerGatewayAllowedThread{}
	}
	floor, hasFloor := r.gatewayThreadRestrictions[key]
	merged, anyOK := applyFloorToAllowedThread(mainEntry, ok, floor, hasFloor)
	return merged, ok, anyOK
}

// recordGatewayThreadRestrictionLocked 要求调用方已持有 r.gatewayThreadsMu。
// 将永久只读与显式禁写版本同步写入底板；满载淘汰最旧底板时递增 gatewayRestrictionEvictionEpoch，
// 迫使活跃连接先使未由真实主表背书的旧缓存失效。
func (r *Router) recordGatewayThreadRestrictionLocked(key string, thread appServerGatewayAllowedThread, now time.Time) {
	if r == nil {
		return
	}
	thread = normalizeAllowedThreadRestrictionBits(thread)
	if !thread.readOnlyPermanent && !thread.explicitDirectInputDenied && thread.explicitDirectInputVersion == 0 {
		return
	}
	if r.gatewayThreadRestrictions == nil {
		r.gatewayThreadRestrictions = map[string]gatewayThreadRestrictionFloor{}
	}
	existing, exists := r.gatewayThreadRestrictions[key]
	floor := gatewayThreadRestrictionFloor{
		readOnlyPermanent:          existing.readOnlyPermanent || thread.readOnlyPermanent,
		readOnlySubagent:           existing.readOnlySubagent || thread.readOnlySubagent,
		readOnlyBrowseScope:        existing.readOnlyBrowseScope || thread.readOnlyBrowseScope,
		explicitDirectInputDenied:  thread.explicitDirectInputDenied,
		explicitDirectInputVersion: thread.explicitDirectInputVersion,
		lastUpdated:                now,
	}
	if exists {
		switch {
		case existing.explicitDirectInputVersion > thread.explicitDirectInputVersion:
			floor.explicitDirectInputDenied = existing.explicitDirectInputDenied
			floor.explicitDirectInputVersion = existing.explicitDirectInputVersion
		case existing.explicitDirectInputVersion == thread.explicitDirectInputVersion:
			floor.explicitDirectInputDenied = existing.explicitDirectInputDenied || thread.explicitDirectInputDenied
		}
	}
	if !exists && appServerGatewayRestrictionFloorMax > 0 && len(r.gatewayThreadRestrictions) >= appServerGatewayRestrictionFloorMax {
		oldestKey := ""
		var oldestTime time.Time
		for k, item := range r.gatewayThreadRestrictions {
			if oldestKey == "" || item.lastUpdated.Before(oldestTime) {
				oldestKey = k
				oldestTime = item.lastUpdated
			}
		}
		if oldestKey != "" {
			delete(r.gatewayThreadRestrictions, oldestKey)
			r.gatewayRestrictionEvictionEpoch++
		}
	}
	r.gatewayThreadRestrictions[key] = floor
}

// syncRestrictionEvictionEpochLocked 要求调用方按锁序已持有 p.mu 与 r.gatewayThreadsMu。
// 若底板发生过满载淘汰，清空连接级 p.allowedThreads 中所有未由真实非补种主表背书的旧条目。
func (p *appServerGatewayPolicy) syncRestrictionEvictionEpochLocked(now time.Time) {
	if p == nil || p.router == nil {
		return
	}
	if p.restrictionEvictionEpoch == p.router.gatewayRestrictionEvictionEpoch {
		return
	}
	runtimeID := normalizeAppServerRuntimeID(p.runtimeID)
	for id := range p.allowedThreads {
		key := gatewayThreadCacheKey(runtimeID, id)
		mainEntry, ok := p.router.gatewayThreads[key]
		if ok && gatewayThreadCacheExpired(mainEntry, now) {
			delete(p.router.gatewayThreads, key)
			ok = false
		}
		if !ok || mainEntry.pushSeededOnly {
			delete(p.allowedThreads, id)
			continue
		}
		// 仍由真实非补种主表背书的条目，刷新为最新有效主表+底板状态。
		eff, _, _ := p.router.effectiveGatewayThreadLocked(key, now)
		p.allowedThreads[id] = eff
	}
	p.restrictionEvictionEpoch = p.router.gatewayRestrictionEvictionEpoch
}

// applyFinalThreadPermissions 统一将阶段 B 收敛后的最终权限写回 Global 或 Scoped 响应条目。
// Scoped 原行缺 mimiRemote 时必须补建并写入 readOnly / cwdMissing 标记。
func applyFinalThreadPermissions(
	item map[string]any,
	finalThread appServerGatewayAllowedThread,
	liveProject *projects.Project,
	isGlobal bool,
) {
	if isGlobal {
		mimiMeta := map[string]any{
			"projectId":   liveProject.ID,
			"projectName": liveProject.Name,
			"projectPath": liveProject.Path,
			"discovery":   "global",
			"readOnly":    finalThread.readOnly,
		}
		if finalThread.readOnly {
			item["canAcceptDirectInput"] = false
		} else if finalThread.directInputKnown {
			item["canAcceptDirectInput"] = finalThread.canAcceptDirectInput
		}
		if finalThread.cwdMissing {
			item["cwdMissing"] = true
			mimiMeta["cwdMissing"] = true
		}
		item["mimiRemote"] = mimiMeta
		return
	}

	// Scoped 响应：与 enforceReadOnlyThreadResponse 对齐。
	if finalThread.readOnly {
		item["canAcceptDirectInput"] = false
		annotation, _ := item["mimiRemote"].(map[string]any)
		if annotation == nil {
			annotation = map[string]any{}
		}
		annotation["readOnly"] = true
		if finalThread.cwdMissing {
			item["cwdMissing"] = true
			annotation["cwdMissing"] = true
		}
		item["mimiRemote"] = annotation
	} else if finalThread.directInputKnown {
		item["canAcceptDirectInput"] = finalThread.canAcceptDirectInput
	}
}

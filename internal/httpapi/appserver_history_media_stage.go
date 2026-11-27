package httpapi

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"strings"
	"sync"
	"time"
)

var appServerHistoryMediaReadGrace = 5 * time.Second

type preparedBlobInput struct {
	contentType string
	data        []byte
}

type preparedBlobReservation struct {
	store           *appServerHistoryMediaStore
	ids             []string
	admitted        []bool
	newItems        []preparedBlobCommitItem
	reusedPinnedIDs []string
	reservedEntries int
	reservedBytes   int64
	additional      []*preparedBlobReservation
	once            sync.Once
}

type preparedBlobCommitItem struct {
	id          string
	contentType string
	data        []byte
	hash        [32]byte
}

// reservePreparedBatch 在不写入新条目、不淘汰旧条目、不调 pruneLocked 的前提下，
// 对整批 blobs 执行统一容量准入（覆盖活跃 pin、本批新 pin 的既有条目、在途预留与本批新条目）。
// 若任一条超单条上限或整批超双上限，返回 ok=false 且对共享缓存严格零写入、零淘汰。
func (s *appServerHistoryMediaStore) reservePreparedBatch(blobs []preparedBlobInput) (*preparedBlobReservation, bool) {
	if len(blobs) == 0 {
		return &preparedBlobReservation{store: s}, true
	}
	if s == nil {
		return nil, false
	}
	now := s.now()
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.idByHash == nil {
		s.idByHash = map[[32]byte]string{}
	}

	currentlyPinnedEntries, currentlyPinnedBytes := s.pinnedUsageLocked(now)
	newlyPinnedExistingEntries := 0
	newlyPinnedExistingBytes := int64(0)
	newEntries := 0
	newBytes := int64(0)

	ids := make([]string, len(blobs))
	admitted := make([]bool, len(blobs))
	batchByHash := map[[32]byte]string{}
	reusedPinnedSet := map[string]struct{}{}
	reusedPinnedIDs := make([]string, 0)
	newItems := make([]preparedBlobCommitItem, 0)
	usedIDs := map[string]struct{}{}

	for i, blob := range blobs {
		if len(blob.data) == 0 || (s.maxItemBytes > 0 && int64(len(blob.data)) > s.maxItemBytes) {
			return nil, false
		}
		hash := sha256.Sum256(blob.data)
		if batchID, dup := batchByHash[hash]; dup {
			ids[i] = batchID
			admitted[i] = true
			continue
		}

		// 查找同 hash 现存条目，按统一分类规则 A / B / C 记账与加 pin。
		if existingID := s.idByHash[hash]; existingID != "" {
			if existing, exists := s.entries[existingID]; exists {
				if existing.isEffectivelyPinned(now) {
					// 分类 A：复用当前有效 pin 条目（即使已跨 TTL）：零增量，且同样加 activeWritePins++。
					batchByHash[hash] = existingID
					ids[i] = existingID
					admitted[i] = true
					if _, seen := reusedPinnedSet[existingID]; !seen {
						reusedPinnedSet[existingID] = struct{}{}
						reusedPinnedIDs = append(reusedPinnedIDs, existingID)
					}
					continue
				}
				if s.ttl <= 0 || now.Sub(existing.createdAt) <= s.ttl {
					// 分类 B：复用未 pin 且未过期现存条目：计入本批新 pin 的既有条目数与含派生实际字节。
					nextPinnedEntries := currentlyPinnedEntries + newlyPinnedExistingEntries + 1
					nextPinnedBytes := currentlyPinnedBytes + newlyPinnedExistingBytes + existing.totalBytes()
					if (s.maxEntries > 0 && nextPinnedEntries+s.reservedEntries+newEntries > s.maxEntries) ||
						(s.maxBytes > 0 && nextPinnedBytes+s.reservedBytes+newBytes > s.maxBytes) {
						return nil, false
					}
					newlyPinnedExistingEntries++
					newlyPinnedExistingBytes += existing.totalBytes()
					batchByHash[hash] = existingID
					ids[i] = existingID
					admitted[i] = true
					if _, seen := reusedPinnedSet[existingID]; !seen {
						reusedPinnedSet[existingID] = struct{}{}
						reusedPinnedIDs = append(reusedPinnedIDs, existingID)
					}
					continue
				}
				// 分类 C（未 pin 且已过期）：提交时以同 ID 重插刷新，按新条目计费。
				entryBytes := int64(len(blob.data))
				if (s.maxEntries > 0 && currentlyPinnedEntries+newlyPinnedExistingEntries+s.reservedEntries+newEntries+1 > s.maxEntries) ||
					(s.maxBytes > 0 && currentlyPinnedBytes+newlyPinnedExistingBytes+s.reservedBytes+newBytes+entryBytes > s.maxBytes) {
					return nil, false
				}
				newEntries++
				newBytes += entryBytes
				batchByHash[hash] = existingID
				ids[i] = existingID
				admitted[i] = true
				usedIDs[existingID] = struct{}{}
				newItems = append(newItems, preparedBlobCommitItem{
					id:          existingID,
					contentType: blob.contentType,
					data:        append([]byte(nil), blob.data...),
					hash:        hash,
				})
				continue
			}
		}

		// 分类 C（全新条目）。
		entryBytes := int64(len(blob.data))
		if (s.maxEntries > 0 && currentlyPinnedEntries+newlyPinnedExistingEntries+s.reservedEntries+newEntries+1 > s.maxEntries) ||
			(s.maxBytes > 0 && currentlyPinnedBytes+newlyPinnedExistingBytes+s.reservedBytes+newBytes+entryBytes > s.maxBytes) {
			return nil, false
		}
		candidateID, ok := s.nextUniqueIDLocked(usedIDs)
		if !ok {
			return nil, false
		}
		newEntries++
		newBytes += entryBytes
		batchByHash[hash] = candidateID
		ids[i] = candidateID
		admitted[i] = true
		usedIDs[candidateID] = struct{}{}
		newItems = append(newItems, preparedBlobCommitItem{
			id:          candidateID,
			contentType: blob.contentType,
			data:        append([]byte(nil), blob.data...),
			hash:        hash,
		})
	}

	// 整批准入通过：仅登记预留与对复用现存 ID（含分类 A 与分类 B）加 activeWritePins++，
	// 此时仍不写新条目、不淘汰旧条目。
	s.reservedEntries += newEntries
	s.reservedBytes += newBytes
	for _, id := range reusedPinnedIDs {
		if entry, ok := s.entries[id]; ok {
			entry.activeWritePins++
			s.entries[id] = entry
		}
	}
	return &preparedBlobReservation{
		store:           s,
		ids:             ids,
		admitted:        admitted,
		newItems:        newItems,
		reusedPinnedIDs: reusedPinnedIDs,
		reservedEntries: newEntries,
		reservedBytes:   newBytes,
	}, true
}

// reservePreparedBatchGreedy 逐条按统一容量公式准入（超单条上限或达双上限的后续条目保留内联，不发坏引用）。
func (s *appServerHistoryMediaStore) reservePreparedBatchGreedy(blobs []preparedBlobInput) *preparedBlobReservation {
	return s.reservePreparedBatchGreedyWithBatchHash(blobs, nil)
}

func (s *appServerHistoryMediaStore) reservePreparedBatchGreedyWithBatchHash(
	blobs []preparedBlobInput,
	sharedBatchByHash map[[32]byte]string,
) *preparedBlobReservation {
	if len(blobs) == 0 || s == nil {
		return &preparedBlobReservation{store: s, ids: make([]string, len(blobs)), admitted: make([]bool, len(blobs))}
	}
	now := s.now()
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.idByHash == nil {
		s.idByHash = map[[32]byte]string{}
	}

	currentlyPinnedEntries, currentlyPinnedBytes := s.pinnedUsageLocked(now)
	newlyPinnedExistingEntries := 0
	newlyPinnedExistingBytes := int64(0)
	newEntries := 0
	newBytes := int64(0)

	ids := make([]string, len(blobs))
	admitted := make([]bool, len(blobs))
	batchByHash := sharedBatchByHash
	if batchByHash == nil {
		batchByHash = map[[32]byte]string{}
	}
	reusedPinnedSet := map[string]struct{}{}
	reusedPinnedIDs := make([]string, 0)
	newItems := make([]preparedBlobCommitItem, 0)
	usedIDs := map[string]struct{}{}
	for _, existingBatchID := range batchByHash {
		usedIDs[existingBatchID] = struct{}{}
	}

	for i, blob := range blobs {
		if len(blob.data) == 0 || (s.maxItemBytes > 0 && int64(len(blob.data)) > s.maxItemBytes) {
			continue
		}
		hash := sha256.Sum256(blob.data)
		if batchID, dup := batchByHash[hash]; dup {
			ids[i] = batchID
			admitted[i] = true
			continue
		}
		if existingID := s.idByHash[hash]; existingID != "" {
			if existing, exists := s.entries[existingID]; exists {
				if existing.isEffectivelyPinned(now) {
					batchByHash[hash] = existingID
					ids[i] = existingID
					admitted[i] = true
					if _, seen := reusedPinnedSet[existingID]; !seen {
						reusedPinnedSet[existingID] = struct{}{}
						reusedPinnedIDs = append(reusedPinnedIDs, existingID)
					}
					continue
				}
				if s.ttl <= 0 || now.Sub(existing.createdAt) <= s.ttl {
					nextPinnedEntries := currentlyPinnedEntries + newlyPinnedExistingEntries + 1
					nextPinnedBytes := currentlyPinnedBytes + newlyPinnedExistingBytes + existing.totalBytes()
					if (s.maxEntries > 0 && nextPinnedEntries+s.reservedEntries+newEntries > s.maxEntries) ||
						(s.maxBytes > 0 && nextPinnedBytes+s.reservedBytes+newBytes > s.maxBytes) {
						continue
					}
					newlyPinnedExistingEntries++
					newlyPinnedExistingBytes += existing.totalBytes()
					batchByHash[hash] = existingID
					ids[i] = existingID
					admitted[i] = true
					if _, seen := reusedPinnedSet[existingID]; !seen {
						reusedPinnedSet[existingID] = struct{}{}
						reusedPinnedIDs = append(reusedPinnedIDs, existingID)
					}
					continue
				}
				entryBytes := int64(len(blob.data))
				if (s.maxEntries > 0 && currentlyPinnedEntries+newlyPinnedExistingEntries+s.reservedEntries+newEntries+1 > s.maxEntries) ||
					(s.maxBytes > 0 && currentlyPinnedBytes+newlyPinnedExistingBytes+s.reservedBytes+newBytes+entryBytes > s.maxBytes) {
					continue
				}
				newEntries++
				newBytes += entryBytes
				batchByHash[hash] = existingID
				ids[i] = existingID
				admitted[i] = true
				usedIDs[existingID] = struct{}{}
				newItems = append(newItems, preparedBlobCommitItem{
					id:          existingID,
					contentType: blob.contentType,
					data:        append([]byte(nil), blob.data...),
					hash:        hash,
				})
				continue
			}
		}
		entryBytes := int64(len(blob.data))
		if (s.maxEntries > 0 && currentlyPinnedEntries+newlyPinnedExistingEntries+s.reservedEntries+newEntries+1 > s.maxEntries) ||
			(s.maxBytes > 0 && currentlyPinnedBytes+newlyPinnedExistingBytes+s.reservedBytes+newBytes+entryBytes > s.maxBytes) {
			continue
		}
		candidateID, ok := s.nextUniqueIDLocked(usedIDs)
		if !ok {
			continue
		}
		newEntries++
		newBytes += entryBytes
		batchByHash[hash] = candidateID
		ids[i] = candidateID
		admitted[i] = true
		usedIDs[candidateID] = struct{}{}
		newItems = append(newItems, preparedBlobCommitItem{
			id:          candidateID,
			contentType: blob.contentType,
			data:        append([]byte(nil), blob.data...),
			hash:        hash,
		})
	}

	s.reservedEntries += newEntries
	s.reservedBytes += newBytes
	for _, id := range reusedPinnedIDs {
		if entry, ok := s.entries[id]; ok {
			entry.activeWritePins++
			s.entries[id] = entry
		}
	}
	return &preparedBlobReservation{
		store:           s,
		ids:             ids,
		admitted:        admitted,
		newItems:        newItems,
		reusedPinnedIDs: reusedPinnedIDs,
		reservedEntries: newEntries,
		reservedBytes:   newBytes,
	}
}

func (s *appServerHistoryMediaStore) nextUniqueIDLocked(used map[string]struct{}) (string, bool) {
	for attempt := 0; attempt < 8; attempt++ {
		id, ok := randomHistoryMediaID()
		if !ok {
			return "", false
		}
		if _, inStore := s.entries[id]; inStore {
			continue
		}
		if _, inBatch := used[id]; inBatch {
			continue
		}
		return id, true
	}
	return "", false
}

// cancel 释放全部预留与复用 pin，严格零条目写入、零条目淘汰。
func (r *preparedBlobReservation) cancel() {
	if r == nil || r.store == nil {
		return
	}
	r.once.Do(func() {
		s := r.store
		s.mu.Lock()
		s.reservedEntries -= r.reservedEntries
		if s.reservedEntries < 0 {
			s.reservedEntries = 0
		}
		s.reservedBytes -= r.reservedBytes
		if s.reservedBytes < 0 {
			s.reservedBytes = 0
		}
		for _, id := range r.reusedPinnedIDs {
			if entry, ok := s.entries[id]; ok {
				if entry.activeWritePins > 0 {
					entry.activeWritePins--
				}
				s.entries[id] = entry
			}
		}
		s.mu.Unlock()
		for _, extra := range r.additional {
			extra.cancel()
		}
	})
}

// commit 将预留槽位不可失败地落盘至 s.entries，刷新复用条目 createdAt = now，
// 返回 releasePins(grace)：写失败/丢弃传 0 立刻释放，写完传有界首读宽限（如 5s）。
func (r *preparedBlobReservation) commit() func(grace time.Duration) {
	if r == nil || r.store == nil || (len(r.newItems) == 0 && len(r.reusedPinnedIDs) == 0 && len(r.additional) == 0) {
		return nil
	}
	var release func(grace time.Duration)
	r.once.Do(func() {
		var selfRelease func(grace time.Duration)
		if len(r.newItems) > 0 || len(r.reusedPinnedIDs) > 0 {
			s := r.store
			now := s.now()
			s.mu.Lock()
			s.pruneLocked(now)
			s.reservedEntries -= r.reservedEntries
			if s.reservedEntries < 0 {
				s.reservedEntries = 0
			}
			s.reservedBytes -= r.reservedBytes
			if s.reservedBytes < 0 {
				s.reservedBytes = 0
			}
			if s.idByHash == nil {
				s.idByHash = map[[32]byte]string{}
			}
			pinnedIDs := make([]string, 0, len(r.reusedPinnedIDs)+len(r.newItems))
			for _, id := range r.reusedPinnedIDs {
				if entry, ok := s.entries[id]; ok {
					entry.createdAt = now
					s.touchEntryLocked(&entry, now)
					s.entries[id] = entry
					pinnedIDs = append(pinnedIDs, id)
				}
			}
			for _, item := range r.newItems {
				if existing, ok := s.entries[item.id]; ok {
					if existing.isEffectivelyPinned(now) || existing.hash == item.hash {
						// 两个并发预留刷新了同一个过期 ID：复用已提交的存活条目并累加 pin，
						// 绝不删除并重置前一个响应的 activeWritePins / gracePinExpiries。
						existing.createdAt = now
						existing.activeWritePins++
						s.touchEntryLocked(&existing, now)
						s.entries[item.id] = existing
						s.indexHashLocked(item.hash, item.id)
						pinnedIDs = append(pinnedIDs, item.id)
						continue
					}
					s.deleteEntryLocked(item.id, existing)
				}
				entry := appServerHistoryMediaEntry{
					id:              item.id,
					contentType:     item.contentType,
					data:            item.data,
					hash:            item.hash,
					createdAt:       now,
					lastAccess:      now,
					activeWritePins: 1,
				}
				s.touchEntryLocked(&entry, now)
				s.entries[item.id] = entry
				s.indexHashLocked(item.hash, item.id)
				s.totalBytes += entry.totalBytes()
				pinnedIDs = append(pinnedIDs, item.id)
			}
			s.enforceLimitsLocked(now)
			s.mu.Unlock()

			var releaseOnce sync.Once
			selfRelease = func(grace time.Duration) {
				releaseOnce.Do(func() {
					relNow := s.now()
					s.mu.Lock()
					for _, id := range pinnedIDs {
						if entry, ok := s.entries[id]; ok {
							if entry.activeWritePins > 0 {
								entry.activeWritePins--
							}
							if grace > 0 {
								entry.gracePinExpiries = append(entry.gracePinExpiries, relNow.Add(grace))
							}
							s.entries[id] = entry
						}
					}
					s.mu.Unlock()
				})
			}
		}
		extraReleases := make([]func(time.Duration), 0, len(r.additional))
		for _, extra := range r.additional {
			if fn := extra.commit(); fn != nil {
				extraReleases = append(extraReleases, fn)
			}
		}
		if selfRelease != nil || len(extraReleases) > 0 {
			release = func(grace time.Duration) {
				if selfRelease != nil {
					selfRelease(grace)
				}
				for _, fn := range extraReleases {
					fn(grace)
				}
			}
		}
	})
	return release
}

type stagedMediaReplacement struct {
	apply func(id string)
}

// stageRedactAndDehydrateThreadListPayload 对已通过授权裁剪构造出的 thread/list 响应执行
// 暂存模式图片脱敏与大输出脱水（零写入/零淘汰共享缓存），返回预留句柄与改写后载荷。
func (r *Router) stageRedactAndDehydrateThreadListPayload(
	payload []byte,
	redactOnly bool,
) (rewritten []byte, mediaRes *preparedBlobReservation, outputRes *preparedBlobReservation) {
	rewritten = payload
	if r == nil || len(payload) == 0 {
		return rewritten, nil, nil
	}
	if r.historyMedia != nil && (bytes.Contains(rewritten, []byte("data:image/")) ||
		bytes.Contains(rewritten, []byte(`"image"`)) ||
		bytes.Contains(rewritten, []byte(`"imageGeneration"`)) ||
		bytes.Contains(rewritten, []byte(`"mcpToolCall"`)) ||
		bytes.Contains(rewritten, []byte(`"dynamicToolCall"`))) {
		var root any
		dec := json.NewDecoder(bytes.NewReader(rewritten))
		dec.UseNumber()
		if dec.Decode(&root) == nil {
			var blobs []preparedBlobInput
			var reps []stagedMediaReplacement
			collectStagedMediaBlobs(root, &blobs, &reps)
			if len(blobs) > 0 {
				res := r.historyMedia.reservePreparedBatchGreedy(blobs)
				changed := false
				for i, rep := range reps {
					if res.admitted[i] {
						rep.apply(res.ids[i])
						changed = true
					}
				}
				if changed {
					if encoded, err := json.Marshal(root); err == nil {
						rewritten = encoded
						mediaRes = res
					} else {
						res.cancel()
					}
				} else {
					res.cancel()
				}
			}
		}
	}
	overHardCap := appServerGatewayHistoryResponseCapBytes > 0 && len(rewritten) > appServerGatewayHistoryResponseCapBytes
	if !redactOnly && r.historyOutput != nil && (overHardCap || len(rewritten) > appServerHistoryInlinePageBytes) {
		minimumItemBytes := appServerHistoryInlineOutputBytes
		if overHardCap {
			minimumItemBytes = appServerHistoryOutputMinItemBytes
		}
		if bytes.Contains(rewritten, []byte(`"commandExecution"`)) ||
			bytes.Contains(rewritten, []byte(`"mcpToolCall"`)) ||
			bytes.Contains(rewritten, []byte(`"dynamicToolCall"`)) ||
			bytes.Contains(rewritten, []byte(`"collabAgentToolCall"`)) ||
			bytes.Contains(rewritten, []byte(`"webSearch"`)) ||
			bytes.Contains(rewritten, []byte(`"fileChange"`)) {
			var root any
			dec := json.NewDecoder(bytes.NewReader(rewritten))
			dec.UseNumber()
			if dec.Decode(&root) == nil {
				res, changed := stageOutputWaves(root, minimumItemBytes, r.historyOutput)
				if changed && res != nil {
					if encoded, err := json.Marshal(root); err == nil && len(encoded) < len(rewritten) {
						rewritten = encoded
						outputRes = res
					} else {
						res.cancel()
					}
				} else if res != nil {
					res.cancel()
				}
			}
		}
	}
	return rewritten, mediaRes, outputRes
}

func collectStagedMediaBlobs(value any, blobs *[]preparedBlobInput, reps *[]stagedMediaReplacement) {
	switch typed := value.(type) {
	case map[string]any:
		rawType, _ := typed["type"].(string)
		trimmedType := strings.TrimSpace(rawType)
		handledImage := false
		if trimmedType == "image" {
			rawURL, _ := typed["url"].(string)
			contentType, data, ok := decodeHistoryImageDataURL(rawURL)
			if !ok {
				rawData, _ := typed["data"].(string)
				contentType, data, ok = decodeHistoryInlineImage(rawData)
			}
			if ok {
				handledImage = true
				obj, ct, n := typed, contentType, len(data)
				*blobs = append(*blobs, preparedBlobInput{contentType: ct, data: data})
				*reps = append(*reps, stagedMediaReplacement{apply: func(id string) {
					obj["url"] = appServerHistoryMediaURLPrefix + id
					delete(obj, "data")
					obj["contentType"] = ct
					obj["byteCount"] = n
					obj["redacted"] = true
				}})
			}
		}
		if trimmedType == "imageGeneration" {
			rawResult, _ := typed["result"].(string)
			if contentType, data, ok := decodeHistoryRawBase64Image(rawResult); ok {
				obj, ct, n := typed, contentType, len(data)
				*blobs = append(*blobs, preparedBlobInput{contentType: ct, data: data})
				*reps = append(*reps, stagedMediaReplacement{apply: func(id string) {
					obj["result"] = appServerHistoryMediaURLPrefix + id
					obj["resultContentType"] = ct
					obj["resultByteCount"] = n
					obj["resultRedacted"] = true
				}})
			}
		}
		if trimmedType == "mcpToolCall" || trimmedType == "dynamicToolCall" {
			for _, field := range []string{"url", "result"} {
				rawValue, _ := typed[field].(string)
				if contentType, data, ok := decodeHistoryInlineImage(rawValue); ok {
					obj, f, ct, n := typed, field, contentType, len(data)
					if f == "url" {
						handledImage = true
					}
					*blobs = append(*blobs, preparedBlobInput{contentType: ct, data: data})
					*reps = append(*reps, stagedMediaReplacement{apply: func(id string) {
						obj[f] = appServerHistoryMediaURLPrefix + id
						obj[f+"ContentType"] = ct
						obj[f+"ByteCount"] = n
						obj[f+"Redacted"] = true
					}})
				}
			}
		}
		if !handledImage {
			rawURL, _ := typed["url"].(string)
			if contentType, data, ok := decodeHistoryImageDataURL(rawURL); ok {
				obj, ct, n := typed, contentType, len(data)
				*blobs = append(*blobs, preparedBlobInput{contentType: ct, data: data})
				*reps = append(*reps, stagedMediaReplacement{apply: func(id string) {
					obj["url"] = appServerHistoryMediaURLPrefix + id
					obj["urlContentType"] = ct
					obj["urlByteCount"] = n
					obj["urlRedacted"] = true
				}})
			}
		}
		for _, child := range typed {
			collectStagedMediaBlobs(child, blobs, reps)
		}
	case []any:
		for _, child := range typed {
			collectStagedMediaBlobs(child, blobs, reps)
		}
	}
}

// estimateJSONBytesWithinLimit 在调用 json.Marshal 之前无分配预估 JSON 字节数，
// 一旦超过 limit 立即早退，避免在超限父节点上分配整块临时序列化缓冲。
func estimateJSONBytesWithinLimit(value any, limit int64) (int64, bool) {
	var total int64
	var walk func(v any) bool
	walk = func(v any) bool {
		switch typed := v.(type) {
		case nil:
			total += 4
		case bool:
			if typed {
				total += 4
			} else {
				total += 5
			}
		case json.Number:
			total += int64(len(typed))
		case float64, int, int64:
			total += 20
		case string:
			total += int64(len(typed)) + 2
		case []any:
			total += 2
			for i, elem := range typed {
				if i > 0 {
					total++
				}
				if limit > 0 && total > limit {
					return false
				}
				if !walk(elem) {
					return false
				}
			}
		case map[string]any:
			total += 2
			first := true
			for k, elem := range typed {
				if !first {
					total++
				}
				first = false
				total += int64(len(k)) + 3
				if limit > 0 && total > limit {
					return false
				}
				if !walk(elem) {
					return false
				}
			}
		default:
			total += 16
		}
		return limit <= 0 || total <= limit
	}
	ok := walk(value)
	return total, ok
}

func boundedJSONMarshal(value any, maxBytes int64) ([]byte, int64, bool) {
	est, withinEst := estimateJSONBytesWithinLimit(value, maxBytes)
	if !withinEst {
		return nil, est, false
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		return nil, est, false
	}
	if maxBytes > 0 && int64(len(encoded)) > maxBytes {
		return nil, int64(len(encoded)), false
	}
	return encoded, int64(len(encoded)), true
}

type stagedOutputWaveCandidate struct {
	blob          preparedBlobInput
	rep           stagedMediaReplacement
	deferredChild any
}

const maxOutputStageWaves = 8

// stageOutputWaves 自顶向下按波次延迟脱水：
//   - 每波仅序列化当前最外层候选输出，绝不预先序列化其被覆盖的子树；
//   - 父节点准入成功即立刻替换并跳过整个后代子树（零冗余 CPU/内存）；
//   - 仅当父节点因单条上限或容量被拒时，才在下一波下沉其子节点，跨波共享去重索引并严格限制总临时预算。
func stageOutputWaves(root any, minimumItemBytes int, store *appServerHistoryMediaStore) (*preparedBlobReservation, bool) {
	if store == nil || root == nil {
		return nil, false
	}
	maxItemBytes := store.maxItemBytes
	if store.maxBytes > 0 && (maxItemBytes <= 0 || store.maxBytes < maxItemBytes) {
		maxItemBytes = store.maxBytes
	}
	totalTempBudget := int64(appServerGatewayHistoryResponseCapBytes)
	if store.maxBytes > 0 {
		if b := store.maxBytes * 2; b > totalTempBudget {
			totalTempBudget = b
		}
	}
	if totalTempBudget <= 0 {
		totalTempBudget = 16 << 20
	}
	if totalTempBudget > 32<<20 {
		totalTempBudget = 32 << 20
	}
	// 严禁临时预算低于已配置单条上限，避免合法大输出（如 33 MiB <= 64 MiB）被误留内联。
	if maxItemBytes > totalTempBudget {
		totalTempBudget = maxItemBytes
	}

	var (
		combined        *preparedBlobReservation
		changed         bool
		tempBytesUsed   int64
		waveRoots       = []any{root}
		sharedBatchHash = map[[32]byte]string{}
	)
	for wave := 0; wave < maxOutputStageWaves && len(waveRoots) > 0 && tempBytesUsed < totalTempBudget; wave++ {
		var candidates []stagedOutputWaveCandidate
		var overflowDeferred []any
		for _, subRoot := range waveRoots {
			collectOuterOutputWave(subRoot, minimumItemBytes, maxItemBytes, totalTempBudget, &tempBytesUsed, &candidates, &overflowDeferred)
		}
		var nextWaveRoots []any
		if len(candidates) > 0 {
			blobs := make([]preparedBlobInput, len(candidates))
			for i, cand := range candidates {
				blobs[i] = cand.blob
			}
			res := store.reservePreparedBatchGreedyWithBatchHash(blobs, sharedBatchHash)
			waveAdmitted := false
			for i, cand := range candidates {
				if res.admitted[i] {
					cand.rep.apply(res.ids[i])
					changed = true
					waveAdmitted = true
				} else if cand.deferredChild != nil {
					nextWaveRoots = append(nextWaveRoots, cand.deferredChild)
				}
			}
			if waveAdmitted {
				if combined == nil {
					combined = res
				} else {
					combined.additional = append(combined.additional, res)
				}
			} else {
				res.cancel()
			}
		}
		if len(overflowDeferred) > 0 {
			nextWaveRoots = append(nextWaveRoots, overflowDeferred...)
		}
		waveRoots = nextWaveRoots
	}
	return combined, changed
}

func collectOuterOutputWave(
	value any,
	minimumItemBytes int,
	maxItemBytes int64,
	totalTempBudget int64,
	tempBytesUsed *int64,
	candidates *[]stagedOutputWaveCandidate,
	overflowDeferred *[]any,
) {
	if *tempBytesUsed >= totalTempBudget {
		return
	}
	switch typed := value.(type) {
	case map[string]any:
		skipKey := ""
		if _, alreadyRedacted := typed["historyOutputRef"]; !alreadyRedacted {
			typeName, _ := typed["type"].(string)
			typeName = strings.TrimSpace(typeName)
			remaining := totalTempBudget - *tempBytesUsed
			itemCap := maxItemBytes
			if itemCap <= 0 || remaining < itemCap {
				itemCap = remaining
			}
			var (
				data          []byte
				contentType   string
				preview       string
				replace       func()
				fieldKey      string
				deferredChild any
				overflowed    bool
			)
			switch typeName {
			case "commandExecution":
				output, _ := typed["aggregatedOutput"].(string)
				if len(output) >= minimumItemBytes {
					if itemCap > 0 && int64(len(output)) > itemCap {
						overflowed = true
					} else {
						data = []byte(output)
						contentType = "text/plain; charset=utf-8"
						preview = historyOutputPreview(data)
						obj, p := typed, preview
						fieldKey = "aggregatedOutput"
						replace = func() { obj["aggregatedOutput"] = p }
					}
				}
			case "mcpToolCall", "dynamicToolCall", "collabAgentToolCall", "webSearch":
				if result, ok := typed["result"]; ok && result != nil {
					if text, isStr := result.(string); isStr {
						if len(text) >= minimumItemBytes {
							if itemCap > 0 && int64(len(text)) > itemCap {
								overflowed = true
							} else {
								data = []byte(text)
								contentType = "text/plain; charset=utf-8"
								preview = historyOutputPreview(data)
								obj, p := typed, preview
								fieldKey = "result"
								replace = func() { obj["result"] = p }
							}
						}
					} else {
						encoded, cost, withinCap := boundedJSONMarshal(result, itemCap)
						if !withinCap {
							*tempBytesUsed += cost
							overflowed = true
							skipKey = "result"
							*overflowDeferred = append(*overflowDeferred, result)
						} else if len(encoded) >= minimumItemBytes {
							data = encoded
							contentType = "application/json"
							preview = historyOutputPreview(data)
							obj, p := typed, preview
							fieldKey = "result"
							deferredChild = result
							replace = func() { obj["result"] = p }
						}
					}
				}
			case "fileChange":
				if changes, ok := typed["changes"].([]any); ok && len(changes) > 0 {
					encoded, cost, withinCap := boundedJSONMarshal(changes, itemCap)
					if !withinCap {
						*tempBytesUsed += cost
						overflowed = true
						skipKey = "changes"
						*overflowDeferred = append(*overflowDeferred, changes)
					} else if len(encoded) >= minimumItemBytes {
						data = encoded
						contentType = "application/json"
						preview = historyOutputPreview(data)
						obj, compact := typed, compactHistoryFileChanges(changes)
						fieldKey = "changes"
						deferredChild = changes
						replace = func() { obj["changes"] = compact }
					}
				}
			}
			if !overflowed && len(data) >= minimumItemBytes && replace != nil {
				obj, ct, p, n, fn := typed, contentType, preview, len(data), replace
				skipKey = fieldKey
				*tempBytesUsed += int64(n)
				*candidates = append(*candidates, stagedOutputWaveCandidate{
					blob: preparedBlobInput{contentType: ct, data: data},
					rep: stagedMediaReplacement{apply: func(id string) {
						fn()
						obj["historyOutputRef"] = appServerHistoryOutputURLPrefix + id
						obj["historyOutputByteCount"] = n
						obj["historyOutputContentType"] = ct
						obj["historyOutputPreview"] = p
						obj["historyOutputRedacted"] = true
					}},
					deferredChild: deferredChild,
				})
			}
		}
		for key, child := range typed {
			if skipKey != "" && key == skipKey {
				continue
			}
			collectOuterOutputWave(child, minimumItemBytes, maxItemBytes, totalTempBudget, tempBytesUsed, candidates, overflowDeferred)
		}
	case []any:
		for _, child := range typed {
			collectOuterOutputWave(child, minimumItemBytes, maxItemBytes, totalTempBudget, tempBytesUsed, candidates, overflowDeferred)
		}
	}
}

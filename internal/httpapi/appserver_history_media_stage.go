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
	contentType        string
	data               []byte
	parentIndexPlusOne int
}

type preparedBlobReservation struct {
	store           *appServerHistoryMediaStore
	ids             []string
	admitted        []bool
	newItems        []preparedBlobCommitItem
	reusedPinnedIDs []string
	reservedEntries int
	reservedBytes   int64
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
	batchByHash := map[[32]byte]string{}
	reusedPinnedSet := map[string]struct{}{}
	reusedPinnedIDs := make([]string, 0)
	newItems := make([]preparedBlobCommitItem, 0)
	usedIDs := map[string]struct{}{}

	for i, blob := range blobs {
		ancestorAdmitted := false
		for p := blob.parentIndexPlusOne; p > 0; p = blobs[p-1].parentIndexPlusOne {
			if admitted[p-1] {
				ancestorAdmitted = true
				break
			}
		}
		if ancestorAdmitted {
			continue
		}
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
		defer s.mu.Unlock()
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
	})
}

// commit 将预留槽位不可失败地落盘至 s.entries，刷新复用条目 createdAt = now，
// 返回 releasePins(grace)：写失败/丢弃传 0 立刻释放，写完传有界首读宽限（如 5s）。
func (r *preparedBlobReservation) commit() func(grace time.Duration) {
	if r == nil || r.store == nil || (len(r.newItems) == 0 && len(r.reusedPinnedIDs) == 0) {
		return nil
	}
	var release func(grace time.Duration)
	r.once.Do(func() {
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
		release = func(grace time.Duration) {
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
				var blobs []preparedBlobInput
				var reps []stagedMediaReplacement
				collectStagedOutputBlobs(root, minimumItemBytes, 0, &blobs, &reps)
				if len(blobs) > 0 {
					res := r.historyOutput.reservePreparedBatchGreedy(blobs)
					changed := false
					for i, rep := range reps {
						if res.admitted[i] {
							rep.apply(res.ids[i])
							changed = true
						}
					}
					if changed {
						if encoded, err := json.Marshal(root); err == nil && len(encoded) < len(rewritten) {
							rewritten = encoded
							outputRes = res
						} else {
							res.cancel()
						}
					} else {
						res.cancel()
					}
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

func collectStagedOutputBlobs(value any, minimumItemBytes int, parentIndexPlusOne int, blobs *[]preparedBlobInput, reps *[]stagedMediaReplacement) {
	switch typed := value.(type) {
	case map[string]any:
		replacedKey := ""
		childParentIndexPlusOne := parentIndexPlusOne
		if _, alreadyRedacted := typed["historyOutputRef"]; !alreadyRedacted {
			typeName, _ := typed["type"].(string)
			typeName = strings.TrimSpace(typeName)
			var (
				data        []byte
				contentType string
				preview     string
				replace     func()
				fieldKey    string
			)
			switch typeName {
			case "commandExecution":
				output, _ := typed["aggregatedOutput"].(string)
				data = []byte(output)
				contentType = "text/plain; charset=utf-8"
				preview = historyOutputPreview(data)
				obj, p := typed, preview
				fieldKey = "aggregatedOutput"
				replace = func() { obj["aggregatedOutput"] = p }
			case "mcpToolCall", "dynamicToolCall", "collabAgentToolCall", "webSearch":
				if result, ok := typed["result"]; ok && result != nil {
					if text, ok := result.(string); ok {
						data = []byte(text)
						contentType = "text/plain; charset=utf-8"
					} else {
						data, _ = json.Marshal(result)
						contentType = "application/json"
					}
					preview = historyOutputPreview(data)
					obj, p := typed, preview
					fieldKey = "result"
					replace = func() { obj["result"] = p }
				}
			case "fileChange":
				if changes, ok := typed["changes"].([]any); ok && len(changes) > 0 {
					data, _ = json.Marshal(changes)
					contentType = "application/json"
					preview = historyOutputPreview(data)
					obj, compact := typed, compactHistoryFileChanges(changes)
					fieldKey = "changes"
					replace = func() { obj["changes"] = compact }
				}
			}
			if len(data) >= minimumItemBytes && replace != nil {
				obj, ct, p, n, fn := typed, contentType, preview, len(data), replace
				replacedKey = fieldKey
				*blobs = append(*blobs, preparedBlobInput{
					contentType:        ct,
					data:               data,
					parentIndexPlusOne: parentIndexPlusOne,
				})
				childParentIndexPlusOne = len(*blobs)
				*reps = append(*reps, stagedMediaReplacement{apply: func(id string) {
					fn()
					obj["historyOutputRef"] = appServerHistoryOutputURLPrefix + id
					obj["historyOutputByteCount"] = n
					obj["historyOutputContentType"] = ct
					obj["historyOutputPreview"] = p
					obj["historyOutputRedacted"] = true
				}})
			}
		}
		for key, child := range typed {
			nextParent := parentIndexPlusOne
			if replacedKey != "" && key == replacedKey {
				// 将被父节点覆盖的子树标记为该父节点的后代：
				// 仅在父节点准入成功后跳过后代预留；若父节点因容量/单条上限被拒，后代仍可独立脱水。
				nextParent = childParentIndexPlusOne
			}
			collectStagedOutputBlobs(child, minimumItemBytes, nextParent, blobs, reps)
		}
	case []any:
		for _, child := range typed {
			collectStagedOutputBlobs(child, minimumItemBytes, parentIndexPlusOne, blobs, reps)
		}
	}
}

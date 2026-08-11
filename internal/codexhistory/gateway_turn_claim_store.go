package codexhistory

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	gatewayTurnClaimStoreVersion  = 1
	gatewayTurnClaimStoreMaxBytes = 512 * 1024
	gatewayTurnClaimStoreLimit    = 512
	// 保持现有 40 分钟的 owned claim TTL。它只限制 gateway 归属证据的保存时长，
	// 不决定 external turn 是否仍 active；claim 过期后会安全降级为只读 external。
	gatewayOwnedTurnClaimTTL = 40 * time.Minute
	// 长 turn 只在 rollout 确实继续写入时延长证据，且限制落盘频率，避免流式事件导致频繁 fsync。
	gatewayOwnedTurnClaimRefreshInterval = time.Minute
)

type gatewayOwnedTurnClaim struct {
	threadID       string
	turnID         string
	lastEvidenceAt time.Time
}

type gatewayTurnClaimStoreFile struct {
	Version int                                 `json:"version"`
	Pending []gatewayTurnPendingClaimStoreEntry `json:"pending,omitempty"`
	Owned   []gatewayTurnOwnedClaimStoreEntry   `json:"owned,omitempty"`
}

type gatewayTurnPendingClaimStoreEntry struct {
	ThreadID            string    `json:"thread_id"`
	ClientUserMessageID string    `json:"client_user_message_id"`
	RegisteredAt        time.Time `json:"registered_at"`
}

type gatewayTurnOwnedClaimStoreEntry struct {
	ThreadID       string    `json:"thread_id"`
	TurnID         string    `json:"turn_id"`
	LastEvidenceAt time.Time `json:"last_evidence_at"`
}

type gatewayTurnClaimStore struct {
	path string
}

// 生产环境同一时间只运行一个 agentd；这个锁仍能避免同进程测试或未来多 Router
// 在原子 rename 前交错写临时文件。跨进程读取始终只会看到完整旧文件或完整新文件。
var gatewayTurnClaimStoreWriteMu sync.Mutex

func newGatewayTurnClaimStore(path string) *gatewayTurnClaimStore {
	path = strings.TrimSpace(path)
	if path == "" || !filepath.IsAbs(path) {
		return nil
	}
	return &gatewayTurnClaimStore{path: filepath.Clean(path)}
}

func (s *gatewayTurnClaimStore) load() (gatewayTurnClaimStoreFile, error) {
	if s == nil || strings.TrimSpace(s.path) == "" {
		return gatewayTurnClaimStoreFile{Version: gatewayTurnClaimStoreVersion}, nil
	}
	info, err := os.Lstat(s.path)
	if err != nil {
		return gatewayTurnClaimStoreFile{}, err
	}
	if !info.Mode().IsRegular() {
		return gatewayTurnClaimStoreFile{}, fmt.Errorf("gateway turn claim store 不是普通文件")
	}
	if runtime.GOOS != "windows" && info.Mode().Perm()&0o077 != 0 {
		return gatewayTurnClaimStoreFile{}, fmt.Errorf("gateway turn claim store 权限过宽")
	}
	if info.Size() <= 0 || info.Size() > gatewayTurnClaimStoreMaxBytes {
		return gatewayTurnClaimStoreFile{}, fmt.Errorf("gateway turn claim store 大小无效")
	}
	raw, err := os.ReadFile(s.path)
	if err != nil {
		return gatewayTurnClaimStoreFile{}, err
	}
	if len(raw) <= 0 || len(raw) > gatewayTurnClaimStoreMaxBytes {
		return gatewayTurnClaimStoreFile{}, fmt.Errorf("gateway turn claim store 读取大小无效")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var stored gatewayTurnClaimStoreFile
	if err := decoder.Decode(&stored); err != nil {
		return gatewayTurnClaimStoreFile{}, err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return gatewayTurnClaimStoreFile{}, fmt.Errorf("gateway turn claim store 包含尾随内容")
	}
	if stored.Version != gatewayTurnClaimStoreVersion {
		return gatewayTurnClaimStoreFile{}, fmt.Errorf("不支持的 gateway turn claim store 版本 %d", stored.Version)
	}
	if len(stored.Pending)+len(stored.Owned) > gatewayTurnClaimStoreLimit {
		return gatewayTurnClaimStoreFile{}, fmt.Errorf("gateway turn claim store 超过数量上限")
	}
	return stored, nil
}

func (s *gatewayTurnClaimStore) save(stored gatewayTurnClaimStoreFile) (resultErr error) {
	if s == nil || strings.TrimSpace(s.path) == "" {
		return nil
	}
	stored.Version = gatewayTurnClaimStoreVersion
	raw, err := json.Marshal(stored)
	if err != nil {
		return err
	}
	if len(raw)+1 > gatewayTurnClaimStoreMaxBytes {
		return fmt.Errorf("gateway turn claim store 编码后超过大小上限")
	}

	gatewayTurnClaimStoreWriteMu.Lock()
	defer gatewayTurnClaimStoreWriteMu.Unlock()

	dir := filepath.Dir(s.path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	dirInfo, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	if !dirInfo.IsDir() || dirInfo.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("gateway turn claim store 目录无效")
	}
	if runtime.GOOS != "windows" {
		if err := os.Chmod(dir, 0o700); err != nil {
			return err
		}
	}
	staged, err := os.CreateTemp(dir, ".gateway-turn-claims-*.tmp")
	if err != nil {
		return err
	}
	stagedPath := staged.Name()
	defer func() {
		_ = staged.Close()
		if resultErr != nil {
			_ = os.Remove(stagedPath)
		}
	}()
	if runtime.GOOS != "windows" {
		if err := staged.Chmod(0o600); err != nil {
			return err
		}
	}
	if _, err := staged.Write(append(raw, '\n')); err != nil {
		return err
	}
	if err := staged.Sync(); err != nil {
		return err
	}
	if err := staged.Close(); err != nil {
		return err
	}
	if err := os.Rename(stagedPath, s.path); err != nil {
		return err
	}
	if runtime.GOOS != "windows" {
		if err := os.Chmod(s.path, 0o600); err != nil {
			return err
		}
		dirFile, err := os.Open(dir)
		if err != nil {
			return err
		}
		syncErr := dirFile.Sync()
		closeErr := dirFile.Close()
		if syncErr != nil {
			return syncErr
		}
		if closeErr != nil {
			return closeErr
		}
	}
	return nil
}

func (t *ExternalActivityTracker) ensureGatewayTurnClaimsLoaded(now time.Time) {
	if t.gatewayClaimsLoaded {
		return
	}
	t.gatewayClaimsLoaded = true
	if t.gatewayTurns == nil {
		t.gatewayTurns = map[string]gatewayTurnRegistration{}
	}
	if t.ownedGatewayTurns == nil {
		t.ownedGatewayTurns = map[string]gatewayOwnedTurnClaim{}
	}
	if t.gatewayClaimStore == nil {
		return
	}
	stored, err := t.gatewayClaimStore.load()
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			t.diagnostics.ClaimStoreErrors++
		}
		// 文件损坏、版本不支持或权限失败时不采用任何 claim，宁可保留只读保护。
		return
	}

	seen := map[string]struct{}{}
	for _, pending := range stored.Pending {
		key := gatewayTurnRegistrationKey(pending.ThreadID, pending.ClientUserMessageID)
		registeredAt := pending.RegisteredAt.UTC()
		if !validGatewayClaimID(pending.ThreadID) ||
			!validGatewayClaimID(pending.ClientUserMessageID) ||
			registeredAt.IsZero() ||
			registeredAt.After(now.Add(gatewayTurnEventClockSkew)) ||
			now.After(registeredAt.Add(gatewayTurnRegistrationTTL)) {
			t.gatewayClaimsDirty = true
			continue
		}
		if _, duplicate := seen["pending\x00"+key]; duplicate {
			t.gatewayClaimsDirty = true
			continue
		}
		seen["pending\x00"+key] = struct{}{}
		t.gatewayTurns[key] = gatewayTurnRegistration{registeredAt: registeredAt}
	}
	for _, owned := range stored.Owned {
		key := gatewayOwnedTurnClaimKey(owned.ThreadID, owned.TurnID)
		lastEvidenceAt := owned.LastEvidenceAt.UTC()
		if !validGatewayClaimID(owned.ThreadID) ||
			!validGatewayClaimID(owned.TurnID) ||
			lastEvidenceAt.IsZero() ||
			lastEvidenceAt.After(now.Add(gatewayTurnEventClockSkew)) ||
			now.After(lastEvidenceAt.Add(gatewayOwnedTurnClaimTTL)) {
			t.gatewayClaimsDirty = true
			continue
		}
		if _, duplicate := seen["owned\x00"+key]; duplicate {
			t.gatewayClaimsDirty = true
			continue
		}
		seen["owned\x00"+key] = struct{}{}
		t.ownedGatewayTurns[key] = gatewayOwnedTurnClaim{
			threadID:       strings.TrimSpace(owned.ThreadID),
			turnID:         strings.TrimSpace(owned.TurnID),
			lastEvidenceAt: lastEvidenceAt,
		}
	}
	t.trimGatewayTurnClaims()
}

func (t *ExternalActivityTracker) persistGatewayTurnClaims() {
	if !t.gatewayClaimsDirty || t.gatewayClaimStore == nil {
		return
	}
	stored := gatewayTurnClaimStoreFile{
		Version: gatewayTurnClaimStoreVersion,
		Pending: make([]gatewayTurnPendingClaimStoreEntry, 0, len(t.gatewayTurns)),
		Owned:   make([]gatewayTurnOwnedClaimStoreEntry, 0, len(t.ownedGatewayTurns)),
	}
	for key, registration := range t.gatewayTurns {
		threadID, clientID, ok := splitGatewayTurnClaimKey(key)
		if !ok {
			continue
		}
		stored.Pending = append(stored.Pending, gatewayTurnPendingClaimStoreEntry{
			ThreadID:            threadID,
			ClientUserMessageID: clientID,
			RegisteredAt:        registration.registeredAt.UTC(),
		})
	}
	for _, owned := range t.ownedGatewayTurns {
		stored.Owned = append(stored.Owned, gatewayTurnOwnedClaimStoreEntry{
			ThreadID:       owned.threadID,
			TurnID:         owned.turnID,
			LastEvidenceAt: owned.lastEvidenceAt.UTC(),
		})
	}
	sort.Slice(stored.Pending, func(i, j int) bool {
		if stored.Pending[i].RegisteredAt.Equal(stored.Pending[j].RegisteredAt) {
			if stored.Pending[i].ThreadID == stored.Pending[j].ThreadID {
				return stored.Pending[i].ClientUserMessageID < stored.Pending[j].ClientUserMessageID
			}
			return stored.Pending[i].ThreadID < stored.Pending[j].ThreadID
		}
		return stored.Pending[i].RegisteredAt.Before(stored.Pending[j].RegisteredAt)
	})
	sort.Slice(stored.Owned, func(i, j int) bool {
		if stored.Owned[i].LastEvidenceAt.Equal(stored.Owned[j].LastEvidenceAt) {
			if stored.Owned[i].ThreadID == stored.Owned[j].ThreadID {
				return stored.Owned[i].TurnID < stored.Owned[j].TurnID
			}
			return stored.Owned[i].ThreadID < stored.Owned[j].ThreadID
		}
		return stored.Owned[i].LastEvidenceAt.Before(stored.Owned[j].LastEvidenceAt)
	})
	if err := t.gatewayClaimStore.save(stored); err != nil {
		t.diagnostics.ClaimStoreErrors++
		return
	}
	t.gatewayClaimsDirty = false
	t.diagnostics.ClaimStoreWrites++
}

func (t *ExternalActivityTracker) setGatewayOwnedTurnClaim(threadID string, turnID string, evidenceAt time.Time) {
	threadID = strings.TrimSpace(threadID)
	turnID = strings.TrimSpace(turnID)
	if !validGatewayClaimID(threadID) || !validGatewayClaimID(turnID) || evidenceAt.IsZero() {
		return
	}
	evidenceAt = evidenceAt.UTC()
	key := gatewayOwnedTurnClaimKey(threadID, turnID)
	existing, ok := t.ownedGatewayTurns[key]
	if ok && !evidenceAt.After(existing.lastEvidenceAt) {
		return
	}
	t.ownedGatewayTurns[key] = gatewayOwnedTurnClaim{
		threadID:       threadID,
		turnID:         turnID,
		lastEvidenceAt: evidenceAt,
	}
	t.gatewayClaimsDirty = true
	t.removeOtherGatewayOwnedTurnClaims(threadID, turnID)
	t.trimGatewayTurnClaims()
}

func (t *ExternalActivityTracker) refreshGatewayOwnedTurnClaim(
	threadID string,
	turnID string,
	evidenceAt time.Time,
	now time.Time,
) {
	key := gatewayOwnedTurnClaimKey(threadID, turnID)
	existing, ok := t.ownedGatewayTurns[key]
	if !ok || evidenceAt.IsZero() {
		return
	}
	evidenceAt = evidenceAt.UTC()
	now = now.UTC()
	if evidenceAt.After(now) {
		evidenceAt = now
	}
	if !evidenceAt.After(existing.lastEvidenceAt.Add(gatewayOwnedTurnClaimRefreshInterval)) {
		return
	}
	existing.lastEvidenceAt = evidenceAt
	t.ownedGatewayTurns[key] = existing
	t.gatewayClaimsDirty = true
}

func (t *ExternalActivityTracker) hasGatewayOwnedTurnClaim(threadID string, turnID string) bool {
	_, ok := t.ownedGatewayTurns[gatewayOwnedTurnClaimKey(threadID, turnID)]
	return ok
}

func (t *ExternalActivityTracker) removeGatewayOwnedTurnClaim(threadID string, turnID string) {
	key := gatewayOwnedTurnClaimKey(threadID, turnID)
	if _, ok := t.ownedGatewayTurns[key]; !ok {
		return
	}
	delete(t.ownedGatewayTurns, key)
	t.gatewayClaimsDirty = true
}

func (t *ExternalActivityTracker) removeOtherGatewayOwnedTurnClaims(threadID string, keepTurnID string) {
	threadID = strings.TrimSpace(threadID)
	keepTurnID = strings.TrimSpace(keepTurnID)
	for key, claim := range t.ownedGatewayTurns {
		if claim.threadID == threadID && claim.turnID != keepTurnID {
			delete(t.ownedGatewayTurns, key)
			t.gatewayClaimsDirty = true
		}
	}
}

func (t *ExternalActivityTracker) removeSupersededGatewayOwnedTurnClaims(
	threadID string,
	keepTurnID string,
	turnStartedAt time.Time,
) {
	threadID = strings.TrimSpace(threadID)
	keepTurnID = strings.TrimSpace(keepTurnID)
	turnStartedAt = turnStartedAt.UTC()
	for key, claim := range t.ownedGatewayTurns {
		if claim.threadID != threadID || claim.turnID == keepTurnID {
			continue
		}
		if !turnStartedAt.IsZero() && turnStartedAt.Before(claim.lastEvidenceAt) {
			// Router/Tracker 重建后的全量扫描会先看到历史 turn；只有时间
			// 前进的不同 turn 才能撤销当前 claim。
			continue
		}
		delete(t.ownedGatewayTurns, key)
		t.gatewayClaimsDirty = true
	}
}

func (t *ExternalActivityTracker) pruneGatewayOwnedTurnClaims(now time.Time) {
	for key, claim := range t.ownedGatewayTurns {
		if now.After(claim.lastEvidenceAt.Add(gatewayOwnedTurnClaimTTL)) {
			delete(t.ownedGatewayTurns, key)
			t.gatewayClaimsDirty = true
		}
	}
}

func (t *ExternalActivityTracker) trimGatewayTurnClaims() {
	for len(t.gatewayTurns)+len(t.ownedGatewayTurns) > gatewayTurnClaimStoreLimit {
		var oldestPendingKey string
		var oldestPendingAt time.Time
		for key, registration := range t.gatewayTurns {
			if oldestPendingKey == "" ||
				registration.registeredAt.Before(oldestPendingAt) ||
				(registration.registeredAt.Equal(oldestPendingAt) && key < oldestPendingKey) {
				oldestPendingKey = key
				oldestPendingAt = registration.registeredAt
			}
		}
		var oldestOwnedKey string
		var oldestOwnedAt time.Time
		for key, owned := range t.ownedGatewayTurns {
			if oldestOwnedKey == "" ||
				owned.lastEvidenceAt.Before(oldestOwnedAt) ||
				(owned.lastEvidenceAt.Equal(oldestOwnedAt) && key < oldestOwnedKey) {
				oldestOwnedKey = key
				oldestOwnedAt = owned.lastEvidenceAt
			}
		}
		switch {
		case oldestPendingKey != "" &&
			(oldestOwnedKey == "" || !oldestPendingAt.After(oldestOwnedAt)):
			delete(t.gatewayTurns, oldestPendingKey)
		case oldestOwnedKey != "":
			delete(t.ownedGatewayTurns, oldestOwnedKey)
		default:
			return
		}
		t.gatewayClaimsDirty = true
	}
}

func validGatewayClaimID(value string) bool {
	value = strings.TrimSpace(value)
	return value != "" &&
		len(value) <= gatewayTurnRegistrationIDMax &&
		!strings.ContainsRune(value, '\x00')
}

func gatewayOwnedTurnClaimKey(threadID string, turnID string) string {
	return strings.TrimSpace(threadID) + "\x00" + strings.TrimSpace(turnID)
}

func splitGatewayTurnClaimKey(key string) (string, string, bool) {
	parts := strings.Split(key, "\x00")
	if len(parts) != 2 || !validGatewayClaimID(parts[0]) || !validGatewayClaimID(parts[1]) {
		return "", "", false
	}
	return parts[0], parts[1], true
}

package pushbridge

import (
	"encoding/json"
	"errors"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// 通知定位记录。它只回答「这条通知指向哪台 Mac 上的哪个任务」，本身不含任何
// 审批权限：审批句柄仍只活在内存、随 agentd 重启作废（见 actions.go）。
//
// 定位记录必须跨 agentd 重启存活：用户点开一条早已送达的通知时，agentd 很可能
// 已经重启过；内存路由一丢，iOS 只能把通知当作失效删掉，任务就再也打不开了。
// 记录里刻意不放 Prompt、标题、Token —— 落盘的只有定位一个线程所需的 id。
const (
	RouteKindMessage  = "message"
	RouteKindApproval = "approval"
	routeTTL          = 24 * time.Hour
	maxRoutes         = 256
	routeFileMode     = 0o600
	routeDirMode      = 0o700
	routeWriteLogCap  = 3
)

type LocateRecord struct {
	ID           string    `json:"id"`
	Kind         string    `json:"kind"`
	Runtime      string    `json:"runtime"`
	ThreadID     string    `json:"thread_id"`
	ProjectID    string    `json:"project_id"`
	ScopeID      string    `json:"scope_id,omitempty"`
	CWD          string    `json:"cwd,omitempty"`
	ReadOnly     bool      `json:"read_only,omitempty"`
	TurnID       string    `json:"turn_id,omitempty"`
	Event        string    `json:"event,omitempty"`
	ApprovalKind string    `json:"approval_kind,omitempty"`
	DeviceIDs    []string  `json:"device_ids"`
	CreatedAt    time.Time `json:"created_at"`
	ExpiresAt    time.Time `json:"expires_at"`
}

func (r LocateRecord) allowsDevice(deviceID string) bool {
	if deviceID == "" {
		return false
	}
	for _, allowed := range r.DeviceIDs {
		if allowed == deviceID {
			return true
		}
	}
	return false
}

func (r LocateRecord) sameTurn(other LocateRecord) bool {
	return r.Kind == RouteKindMessage && other.Kind == RouteKindMessage &&
		r.Runtime == other.Runtime && r.ThreadID == other.ThreadID && r.TurnID == other.TurnID
}

// RouteStore 与设备注册表放在同一目录、同样的权限。path 为空时只保留内存视图，
// 让纯内存 Router（单元测试）与落盘 Router 走完全相同的去重、上限和过期逻辑。
type RouteStore struct {
	path string
	// 内存更新（Insert）与落盘（Flush）分离：入站网关帧和审批 broker 只做内存插入，
	// 磁盘写入由投递 goroutine 调用 Flush 完成，不可控的磁盘耗时不会进入网关关键路径。
	// writeMu 串行化落盘并保证快照按生成顺序写入；mu 只保护内存记录与待写快照。
	writeMu    sync.Mutex
	writtenSeq uint64
	failures   int
	mu         sync.Mutex
	records    map[string]LocateRecord
	dirty      []byte
	dirtySeq   uint64
}

// NewRouteStore 永不失败：文件损坏或不可读时记录一次日志后按空记录继续。
// 定位记录丢了只是旧通知打不开，agentd 起不来才是真正的事故。
func NewRouteStore(path string) *RouteStore {
	store := &RouteStore{path: strings.TrimSpace(path), records: map[string]LocateRecord{}}
	store.load(time.Now())
	return store
}

func (s *RouteStore) load(now time.Time) {
	if s.path == "" {
		return
	}
	raw, err := os.ReadFile(s.path)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			log.Printf("push bridge 通知定位记录不可读，按空记录继续 err=%v", err)
		}
		return
	}
	var records []LocateRecord
	if err := json.Unmarshal(raw, &records); err != nil {
		log.Printf("push bridge 通知定位记录损坏，按空记录继续 err=%v", err)
		return
	}
	for _, record := range records {
		// 重启不会延长有效期：过期记录在这里直接丢弃，不再进入内存。
		if strings.TrimSpace(record.ID) == "" || !now.Before(record.ExpiresAt) {
			continue
		}
		s.records[record.ID] = record
	}
}

// Insert 在同一临界区内完成过期清理、按 turn 去重和容量淘汰，返回 false 表示
// 这条 turn 已经推送过（包括重启前落盘的记录），调用方不得再次打扰用户。
func (s *RouteStore) Insert(now time.Time, record LocateRecord) bool {
	if strings.TrimSpace(record.ID) == "" {
		return false
	}
	s.mu.Lock()
	for id, existing := range s.records {
		if !now.Before(existing.ExpiresAt) {
			delete(s.records, id)
			continue
		}
		if existing.sameTurn(record) {
			s.mu.Unlock()
			return false
		}
	}
	if _, exists := s.records[record.ID]; exists {
		s.mu.Unlock()
		return false
	}
	for len(s.records) >= maxRoutes {
		s.evictOldestLocked()
	}
	record.DeviceIDs = append([]string(nil), record.DeviceIDs...)
	s.records[record.ID] = record
	encoded, err := s.snapshotLocked()
	if err == nil && encoded != nil {
		// 只保留最新快照；Flush 时旧快照自然被覆盖，不会以错误顺序写盘。
		s.dirty = encoded
		s.dirtySeq++
	}
	s.mu.Unlock()
	if err != nil {
		log.Printf("push bridge 通知定位记录无法编码 err=%v", err)
	}
	return true
}

// Flush 把最新快照写入磁盘。它由投递闭包在独立 goroutine 中调用，也供测试与关闭
// 流程显式落盘；没有待写快照时立即返回。
func (s *RouteStore) Flush() {
	if s.path == "" {
		return
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	s.mu.Lock()
	encoded, seq := s.dirty, s.dirtySeq
	s.dirty = nil
	s.mu.Unlock()
	if encoded == nil || seq <= s.writtenSeq {
		return
	}
	s.write(encoded)
	s.writtenSeq = seq
}

func (s *RouteStore) Get(id string) (LocateRecord, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	record, ok := s.records[id]
	if !ok {
		return LocateRecord{}, false
	}
	record.DeviceIDs = append([]string(nil), record.DeviceIDs...)
	return record, true
}

func (s *RouteStore) Len() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.records)
}

func (s *RouteStore) evictOldestLocked() {
	oldestID := ""
	var oldestAt time.Time
	for id, record := range s.records {
		if oldestID == "" || record.CreatedAt.Before(oldestAt) ||
			(record.CreatedAt.Equal(oldestAt) && id < oldestID) {
			oldestID = id
			oldestAt = record.CreatedAt
		}
	}
	if oldestID != "" {
		delete(s.records, oldestID)
	}
}

func (s *RouteStore) snapshotLocked() ([]byte, error) {
	if s.path == "" {
		return nil, nil
	}
	records := make([]LocateRecord, 0, len(s.records))
	for _, record := range s.records {
		records = append(records, record)
	}
	sort.Slice(records, func(i, j int) bool {
		if !records[i].CreatedAt.Equal(records[j].CreatedAt) {
			return records[i].CreatedAt.Before(records[j].CreatedAt)
		}
		return records[i].ID < records[j].ID
	})
	return json.MarshalIndent(records, "", "  ")
}

// write 在 writeMu 内、mu 外执行。失败只记录有界日志：定位记录是尽力而为的
// 便利，绝不能反过来阻塞正在推送的 runtime 事件。
func (s *RouteStore) write(encoded []byte) {
	if s.path == "" || encoded == nil {
		return
	}
	err := os.MkdirAll(filepath.Dir(s.path), routeDirMode)
	if err == nil {
		// 先写临时文件再原子替换，避免崩溃时留下半截记录。
		temporary := s.path + ".tmp"
		if err = os.WriteFile(temporary, encoded, routeFileMode); err == nil {
			err = os.Rename(temporary, s.path)
		}
	}
	if err == nil {
		s.failures = 0
		return
	}
	s.failures++
	if s.failures <= routeWriteLogCap {
		log.Printf("push bridge 通知定位记录写入失败 err=%v", err)
	}
	if s.failures == routeWriteLogCap {
		log.Printf("push bridge 通知定位记录连续写入失败，后续同类错误不再记录")
	}
}

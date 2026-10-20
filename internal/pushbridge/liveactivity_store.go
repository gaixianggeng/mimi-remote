package pushbridge

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// Live Activity 票据登记表（#830）。每台已登记消息提醒的设备最多两张：
//   - start：push-to-start Token 换来的 Ticket，只能远程拉起活动；
//   - update：当前那一个活动的更新 Token 换来的 Ticket，只能更新或结束它。
//
// 和设备注册表一样只保存 Provider 签发的不透明密文、到期时间与 App 端活动 ID，
// 看不到原始 Token。落盘是为了 agentd 重启后仍能结束手机上已经存在的活动。
const (
	ActivityTicketStart  = "start"
	ActivityTicketUpdate = "update"

	maxActivityTicketLen   = 4096
	maxActivityIDLen       = 128
	activityTicketFileMode = 0o600
	activityTicketDirMode  = 0o700
)

var (
	errActivityTicketKind    = errors.New("kind 只能是 start 或 update")
	errActivityTicketInvalid = errors.New("ticket 无效")
	errActivityIDInvalid     = errors.New("activity_id 无效")
)

type ActivityTicket struct {
	Ticket       string    `json:"ticket"`
	ExpiresAt    time.Time `json:"expires_at"`
	RegisteredAt time.Time `json:"registered_at"`
	// ActivityID 只属于更新 Ticket：App 注销时按它比对，旧活动的迟到注销不会删掉
	// 新活动刚登记的 Ticket。
	ActivityID string `json:"activity_id,omitempty"`
}

type deviceActivityTickets struct {
	DeviceID string          `json:"device_id"`
	Start    *ActivityTicket `json:"start,omitempty"`
	Update   *ActivityTicket `json:"update,omitempty"`
}

type ActivityTicketStore struct {
	path    string
	mu      sync.Mutex
	devices map[string]*deviceActivityTickets
	now     func() time.Time
}

// NewActivityTicketStore 的 path 为空时只在内存保存。文件损坏按空表继续：活动票据
// 随时可以由 App 重新登记，agentd 不能因此起不来。
func NewActivityTicketStore(path string) *ActivityTicketStore {
	store := &ActivityTicketStore{path: strings.TrimSpace(path), devices: map[string]*deviceActivityTickets{}, now: time.Now}
	store.load()
	return store
}

func ValidActivityTicketKind(kind string) bool {
	return kind == ActivityTicketStart || kind == ActivityTicketUpdate
}

func validActivityID(id string) bool {
	if len(id) > maxActivityIDLen {
		return false
	}
	for _, c := range id {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '-') {
			return false
		}
	}
	return true
}

func (s *ActivityTicketStore) load() {
	if s.path == "" {
		return
	}
	raw, err := os.ReadFile(s.path)
	if err != nil {
		return
	}
	var entries []deviceActivityTickets
	if json.Unmarshal(raw, &entries) != nil {
		return
	}
	for _, entry := range entries {
		entry := entry
		if strings.TrimSpace(entry.DeviceID) == "" || (entry.Start == nil && entry.Update == nil) {
			continue
		}
		s.devices[entry.DeviceID] = &entry
	}
}

func (s *ActivityTicketStore) saveLocked() error {
	if s.path == "" {
		return nil
	}
	entries := make([]deviceActivityTickets, 0, len(s.devices))
	for _, entry := range s.devices {
		entries = append(entries, *entry)
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].DeviceID < entries[j].DeviceID })
	encoded, err := json.MarshalIndent(entries, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.path), activityTicketDirMode); err != nil {
		return err
	}
	temporary := s.path + ".tmp"
	if err := os.WriteFile(temporary, encoded, activityTicketFileMode); err != nil {
		return err
	}
	return os.Rename(temporary, s.path)
}

// Register 新增或替换一张票据。同一设备同一用途只保留最新一张：一次只维持一个活动。
func (s *ActivityTicketStore) Register(deviceID string, kind string, ticket ActivityTicket) (ActivityTicket, error) {
	deviceID = strings.TrimSpace(deviceID)
	ticket.Ticket = strings.TrimSpace(ticket.Ticket)
	ticket.ActivityID = strings.TrimSpace(ticket.ActivityID)
	if deviceID == "" {
		return ActivityTicket{}, errors.New("device_id 必填")
	}
	if !ValidActivityTicketKind(kind) {
		return ActivityTicket{}, errActivityTicketKind
	}
	if ticket.Ticket == "" || len(ticket.Ticket) > maxActivityTicketLen {
		return ActivityTicket{}, errActivityTicketInvalid
	}
	if !validActivityID(ticket.ActivityID) {
		return ActivityTicket{}, errActivityIDInvalid
	}
	if kind == ActivityTicketStart {
		ticket.ActivityID = ""
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	if !ticket.ExpiresAt.After(now) {
		return ActivityTicket{}, errors.New("expires_at 已过期")
	}
	ticket.RegisteredAt = now
	s.pruneLocked(now)
	entry, exists := s.devices[deviceID]
	if !exists {
		entry = &deviceActivityTickets{DeviceID: deviceID}
	}
	previous := *entry
	if kind == ActivityTicketStart {
		entry.Start = &ticket
	} else {
		entry.Update = &ticket
	}
	s.devices[deviceID] = entry
	if err := s.saveLocked(); err != nil {
		if exists {
			*entry = previous
		} else {
			delete(s.devices, deviceID)
		}
		return ActivityTicket{}, err
	}
	return ticket, nil
}

// Remove 注销一张票据。activityID 非空时只在它与当前更新 Ticket 一致时删除。
func (s *ActivityTicketStore) Remove(deviceID string, kind string, activityID string) (bool, error) {
	return s.removeMatching(deviceID, kind, func(ticket *ActivityTicket) bool {
		return activityID == "" || ticket.ActivityID == activityID
	})
}

// RemoveIfTicket 只在登记的仍是这张 Ticket 时删除：投递结果对应的是发出时的快照，
// 期间 App 可能已经登记了新活动。
func (s *ActivityTicketStore) RemoveIfTicket(deviceID string, kind string, value string) (bool, error) {
	return s.removeMatching(deviceID, kind, func(ticket *ActivityTicket) bool {
		return ticket.Ticket == value
	})
}

func (s *ActivityTicketStore) removeMatching(deviceID string, kind string, matches func(*ActivityTicket) bool) (bool, error) {
	if !ValidActivityTicketKind(kind) {
		return false, errActivityTicketKind
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	entry, ok := s.devices[deviceID]
	if !ok {
		return false, nil
	}
	previous := *entry
	slot := &entry.Start
	if kind == ActivityTicketUpdate {
		slot = &entry.Update
	}
	if *slot == nil || !matches(*slot) {
		return false, nil
	}
	*slot = nil
	if entry.Start == nil && entry.Update == nil {
		delete(s.devices, deviceID)
	}
	if err := s.saveLocked(); err != nil {
		*entry = previous
		s.devices[deviceID] = entry
		return false, err
	}
	return true, nil
}

// RemoveDevice 随设备注销一并删除两类票据：删除档案或关闭通知后不再启动或更新活动。
func (s *ActivityTicketStore) RemoveDevice(deviceID string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	entry, ok := s.devices[deviceID]
	if !ok {
		return false, nil
	}
	delete(s.devices, deviceID)
	if err := s.saveLocked(); err != nil {
		s.devices[deviceID] = entry
		return false, err
	}
	return true, nil
}

// Get 返回仍在有效期内的两张票据副本；过期的同时清掉。
func (s *ActivityTicketStore) Get(deviceID string) (start *ActivityTicket, update *ActivityTicket) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneLocked(s.now())
	entry, ok := s.devices[deviceID]
	if !ok {
		return nil, nil
	}
	if entry.Start != nil {
		copied := *entry.Start
		start = &copied
	}
	if entry.Update != nil {
		copied := *entry.Update
		update = &copied
	}
	return start, update
}

func (s *ActivityTicketStore) DeviceIDs() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneLocked(s.now())
	ids := make([]string, 0, len(s.devices))
	for id := range s.devices {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}

func (s *ActivityTicketStore) pruneLocked(now time.Time) {
	changed := false
	for id, entry := range s.devices {
		if entry.Start != nil && !now.Before(entry.Start.ExpiresAt) {
			entry.Start = nil
			changed = true
		}
		if entry.Update != nil && !now.Before(entry.Update.ExpiresAt) {
			entry.Update = nil
			changed = true
		}
		if entry.Start == nil && entry.Update == nil {
			delete(s.devices, id)
			changed = true
		}
	}
	if changed {
		// 内存视图已经正确，写盘失败留给下一次写入重试。
		_ = s.saveLocked()
	}
}

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

// 设备注册表。agentd 只保存 Push Ticket（对它是不透明密文）、device_id、到期
// 时间和最近刷新时间；它看不到里面的 APNs Device Token。
//
// 这份数据需要跨 agentd 重启存活，否则每次重启都要等 App 前台才能恢复提醒。
// 动作句柄则相反 —— 那部分绝不持久化。
const (
	MaxDevices      = 8
	deviceFileMode  = 0o600
	deviceDirMode   = 0o700
	minRefreshAhead = 7 * 24 * time.Hour
)

var errTooManyDevices = errors.New("已注册设备数量达到上限")

type Device struct {
	ID           string    `json:"id"`
	Ticket       string    `json:"ticket"`
	Platform     string    `json:"platform,omitempty"`
	ExpiresAt    time.Time `json:"expires_at"`
	RegisteredAt time.Time `json:"registered_at"`
	RefreshedAt  time.Time `json:"refreshed_at"`
}

// NeedsRefresh 让 App 在 Ticket 剩余不足一周时前台刷新，而不是等它过期后
// 悄悄失去提醒能力。
func (d Device) NeedsRefresh(now time.Time) bool {
	return d.ExpiresAt.Sub(now) < minRefreshAhead
}

type DeviceStore struct {
	path    string
	mu      sync.Mutex
	devices map[string]Device
	now     func() time.Time
}

func NewDeviceStore(path string) (*DeviceStore, error) {
	store := &DeviceStore{path: path, devices: map[string]Device{}, now: time.Now}
	if err := store.load(); err != nil {
		return nil, err
	}
	return store, nil
}

func (s *DeviceStore) load() error {
	raw, err := os.ReadFile(s.path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	var devices []Device
	if err := json.Unmarshal(raw, &devices); err != nil {
		// 文件损坏时按空注册表继续：提醒能力可以重新注册，但 agentd 不能起不来。
		return nil
	}
	for _, device := range devices {
		if strings.TrimSpace(device.ID) == "" {
			continue
		}
		s.devices[device.ID] = device
	}
	return nil
}

func (s *DeviceStore) saveLocked() error {
	devices := make([]Device, 0, len(s.devices))
	for _, device := range s.devices {
		devices = append(devices, device)
	}
	sort.Slice(devices, func(i, j int) bool { return devices[i].ID < devices[j].ID })
	encoded, err := json.MarshalIndent(devices, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.path), deviceDirMode); err != nil {
		return err
	}
	// 先写临时文件再原子替换，避免崩溃时留下半截注册表。
	temporary := s.path + ".tmp"
	if err := os.WriteFile(temporary, encoded, deviceFileMode); err != nil {
		return err
	}
	return os.Rename(temporary, s.path)
}

// Register 新增或刷新一台设备。同一 device_id 重复注册即为刷新，旧 Ticket
// 由调用方负责请求 Provider 撤销。
func (s *DeviceStore) Register(device Device) (Device, error) {
	if strings.TrimSpace(device.ID) == "" || strings.TrimSpace(device.Ticket) == "" {
		return Device{}, errors.New("device_id 与 ticket 必填")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	s.pruneLocked(now)
	existing, exists := s.devices[device.ID]
	if !exists && len(s.devices) >= MaxDevices {
		return Device{}, errTooManyDevices
	}
	if exists {
		device.RegisteredAt = existing.RegisteredAt
	} else {
		device.RegisteredAt = now
	}
	device.RefreshedAt = now
	s.devices[device.ID] = device
	if err := s.saveLocked(); err != nil {
		if exists {
			s.devices[device.ID] = existing
		} else {
			delete(s.devices, device.ID)
		}
		return Device{}, err
	}
	return device, nil
}

// Remove 是「关闭开关」的落点：删除本地 Ticket，让 agentd 立刻停止推送。
// 调用方仍应请求 Provider 把旧 Ticket ID 加入撤销表。
func (s *DeviceStore) Remove(deviceID string) (Device, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	device, ok := s.devices[deviceID]
	if !ok {
		return Device{}, false, nil
	}
	delete(s.devices, deviceID)
	if err := s.saveLocked(); err != nil {
		s.devices[deviceID] = device
		return Device{}, false, err
	}
	return device, true, nil
}

func (s *DeviceStore) Get(deviceID string) (Device, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneLocked(s.now())
	device, ok := s.devices[deviceID]
	return device, ok
}

// Active 返回仍可投递的设备。过期 Ticket 不参与推送，也不再自动续期。
func (s *DeviceStore) Active() []Device {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	s.pruneLocked(now)
	devices := make([]Device, 0, len(s.devices))
	for _, device := range s.devices {
		devices = append(devices, device)
	}
	sort.Slice(devices, func(i, j int) bool { return devices[i].ID < devices[j].ID })
	return devices
}

func (s *DeviceStore) pruneLocked(now time.Time) {
	changed := false
	for id, device := range s.devices {
		if !device.ExpiresAt.IsZero() && !now.Before(device.ExpiresAt) {
			delete(s.devices, id)
			changed = true
		}
	}
	if changed {
		// 忽略保存错误：内存视图已经正确，下一次写入会重试。
		_ = s.saveLocked()
	}
}

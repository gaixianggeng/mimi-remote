//go:build linux

package main

import (
	"fmt"
	"sync"

	"github.com/godbus/dbus/v5"
)

const trayMenuInterface = "com.canonical.dbusmenu"
const trayMenuPath = dbus.ObjectPath("/MenuBar")

type linuxMenuItem struct {
	ID        int32
	Label     string
	Action    string
	Enabled   bool
	Separator bool
	Children  []linuxMenuItem
}

type linuxTraySnapshot struct {
	Status       agentStatus
	HasStatus    bool
	Error        string
	Busy         bool
	Tailcat      linuxTailcatStatus
	HasTailcat   bool
	TailcatError string
	UIError      string
}

func (s linuxTraySnapshot) title() string {
	if !s.HasStatus {
		return "等待服务状态"
	}
	return s.Status.lifecycleTitle()
}

func linuxMenuItems(s linuxTraySnapshot) []linuxMenuItem {
	items := []linuxMenuItem{{ID: 1, Label: "Mimi Remote · " + s.title()}}
	if s.Busy {
		items = append(items, linuxMenuItem{ID: 2, Label: "正在处理…"})
	}
	if s.Error != "" {
		items = append(items, linuxMenuItem{ID: 3, Label: "刷新失败 · " + fallbackText(s.Error, "稍后重试")})
	}
	if s.UIError != "" {
		items = append(items, linuxMenuItem{ID: 9, Label: s.UIError})
	}
	if s.HasStatus {
		if s.Status.RuntimeStatus != nil {
			for i, runtime := range s.Status.RuntimeStatus.Runtimes {
				if !runtime.Enabled {
					continue
				}
				items = append(items, linuxMenuItem{ID: int32(20 + i), Label: fmt.Sprintf("%s · %s", runtime.Title, linuxRuntimeLabel(runtime.State))})
			}
			if s.Status.RuntimeStatus.Stale || s.Status.RuntimeStatus.Refreshing {
				items = append(items, linuxMenuItem{ID: 7, Label: "Runtime 状态正在刷新或已过期"})
			}
		}
		items = append(items, linuxMenuItem{ID: 8, Label: "Tailcat · " + s.tailcatTitle()})
	}
	available := !s.Busy
	fresh := available && s.HasStatus && s.Error == ""
	items = append(items,
		linuxMenuItem{ID: 90, Separator: true},
		linuxMenuItem{ID: 100, Label: "在终端中打开", Action: "status", Enabled: true},
		linuxMenuItem{ID: 101, Label: "刷新状态", Action: "refresh", Enabled: available},
		linuxMenuItem{ID: 102, Label: "Tailcat 配对…", Action: "pair-tailcat", Enabled: fresh && s.Status.ServiceOK},
		linuxMenuItem{ID: 110, Label: "Tailscale 配对…", Action: "pair-tailscale", Enabled: fresh && s.Status.ServiceOK},
		linuxMenuItem{ID: 111, Label: "局域网配对…", Action: "pair-lan", Enabled: fresh && s.Status.ServiceOK && s.Status.NetworkStatus != nil && s.Status.NetworkStatus.AllowLAN},
		linuxMenuItem{ID: 103, Label: "复制连接地址", Action: "copy", Enabled: s.HasStatus && s.Status.Endpoint != ""},
		linuxMenuItem{ID: 91, Separator: true},
		linuxMenuItem{ID: 112, Label: "服务管理", Enabled: true, Children: []linuxMenuItem{
			{ID: 106, Label: "启动服务…", Action: "start", Enabled: fresh && !s.Status.ProcessOK},
			{ID: 107, Label: "重启服务…", Action: "restart", Enabled: fresh && s.Status.ProcessOK},
			{ID: 108, Label: "停止服务…", Action: "stop", Enabled: fresh && s.Status.ProcessOK},
			{ID: 114, Separator: true},
			{ID: 115, Label: "启用 Tailcat…", Action: "tailcat-enable", Enabled: fresh && s.Status.ServiceOK && s.HasTailcat && s.TailcatError == "" && !s.Tailcat.Enabled},
			{ID: 116, Label: "关闭 Tailcat…", Action: "tailcat-disable", Enabled: fresh && s.Status.ServiceOK && s.HasTailcat && s.TailcatError == "" && s.Tailcat.Enabled},
		}},
		linuxMenuItem{ID: 113, Label: "诊断与日志", Enabled: true, Children: []linuxMenuItem{
			{ID: 104, Label: "运行诊断…", Action: "doctor", Enabled: available},
			{ID: 105, Label: "查看日志…", Action: "logs", Enabled: available},
		}},
		linuxMenuItem{ID: 92, Separator: true},
		linuxMenuItem{ID: 109, Label: "退出托盘", Action: "quit", Enabled: true},
	)
	for i := range items {
		items[i].Label = truncateUTF16Text(redactTrayText(items[i].Label), 150)
	}
	return items
}

func (s linuxTraySnapshot) tailcatTitle() string {
	if s.TailcatError != "" || !s.HasTailcat {
		return "状态暂不可用"
	}
	if !s.Tailcat.Enabled {
		return "未启用"
	}
	if !s.Tailcat.Running {
		return "需要处理"
	}
	return fmt.Sprintf("运行中 · %d 台已配对", s.Tailcat.PairedDeviceCount)
}

func linuxRuntimeLabel(state string) string {
	switch state {
	case "connected", "ready":
		return "已连接"
	case "disconnected":
		return "未连接"
	case "connecting":
		return "连接中"
	}
	return state
}

func flattenLinuxMenu(items []linuxMenuItem) []linuxMenuItem {
	var result []linuxMenuItem
	for _, item := range items {
		result = append(result, item)
		result = append(result, flattenLinuxMenu(item.Children)...)
	}
	return result
}

// DBusMenu has the wire layout (ia{sv}av); children must be variants, not
// recursive structs, so clients such as Waybar and Plasma can deserialize it.
type linuxMenuLayout struct {
	ID         int32
	Properties map[string]dbus.Variant
	Children   []dbus.Variant
}
type linuxMenuProperties struct {
	ID         int32
	Properties map[string]dbus.Variant
}
type linuxMenuEvent struct {
	ID        int32
	EventID   string
	Data      dbus.Variant
	Timestamp uint32
}
type linuxDBusMenu struct {
	mu       sync.RWMutex
	items    []linuxMenuItem
	revision uint32
	dispatch func(string)
}

func (m *linuxDBusMenu) update(items []linuxMenuItem) uint32 {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.items = items
	m.revision++
	return m.revision
}
func menuProperties(item linuxMenuItem, names []string) map[string]dbus.Variant {
	all := map[string]dbus.Variant{"label": dbus.MakeVariant(item.Label), "enabled": dbus.MakeVariant(item.Enabled), "visible": dbus.MakeVariant(true)}
	if item.Separator {
		all["type"] = dbus.MakeVariant("separator")
	}
	if len(item.Children) > 0 {
		all["children-display"] = dbus.MakeVariant("submenu")
	}
	if len(names) == 0 {
		return all
	}
	filtered := make(map[string]dbus.Variant)
	for _, name := range names {
		if value, ok := all[name]; ok {
			filtered[name] = value
		}
	}
	return filtered
}
func (m *linuxDBusMenu) GetLayout(parent, depth int32, names []string) (uint32, linuxMenuLayout, *dbus.Error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	root := linuxMenuLayout{ID: parent, Properties: map[string]dbus.Variant{}, Children: []dbus.Variant{}}
	if parent == 0 {
		root.Properties["children-display"] = dbus.MakeVariant("submenu")
		if depth != 0 {
			for _, item := range m.items {
				root.Children = append(root.Children, dbus.MakeVariant(linuxLayout(item, depth-1, names)))
			}
		}
		return m.revision, root, nil
	}
	for _, item := range flattenLinuxMenu(m.items) {
		if item.ID == parent {
			return m.revision, linuxLayout(item, depth, names), nil
		}
	}
	return 0, root, dbus.MakeFailedError(fmt.Errorf("unknown menu item"))
}

func linuxLayout(item linuxMenuItem, depth int32, names []string) linuxMenuLayout {
	layout := linuxMenuLayout{item.ID, menuProperties(item, names), []dbus.Variant{}}
	if depth != 0 {
		for _, child := range item.Children {
			layout.Children = append(layout.Children, dbus.MakeVariant(linuxLayout(child, depth-1, names)))
		}
	}
	return layout
}
func (m *linuxDBusMenu) GetGroupProperties(ids []int32, names []string) ([]linuxMenuProperties, *dbus.Error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	result := []linuxMenuProperties{}
	for _, item := range flattenLinuxMenu(m.items) {
		match := len(ids) == 0
		for _, id := range ids {
			if id == item.ID {
				match = true
			}
		}
		if match {
			result = append(result, linuxMenuProperties{item.ID, menuProperties(item, names)})
		}
	}
	return result, nil
}
func (m *linuxDBusMenu) GetProperty(id int32, name string) (dbus.Variant, *dbus.Error) {
	_, layout, err := m.GetLayout(id, 0, []string{name})
	if err != nil {
		return dbus.MakeVariant(""), err
	}
	if value, ok := layout.Properties[name]; ok {
		return value, nil
	}
	return dbus.MakeVariant(""), dbus.MakeFailedError(fmt.Errorf("unknown property"))
}
func (m *linuxDBusMenu) Event(id int32, event string, data dbus.Variant, timestamp uint32) *dbus.Error {
	if event != "clicked" {
		return nil
	}
	m.mu.RLock()
	action := ""
	for _, item := range flattenLinuxMenu(m.items) {
		if item.ID == id && item.Enabled {
			action = item.Action
			break
		}
	}
	m.mu.RUnlock()
	if action != "" {
		go m.dispatch(action)
	}
	return nil
}
func (m *linuxDBusMenu) EventGroup(events []linuxMenuEvent) ([]int32, *dbus.Error) {
	for _, e := range events {
		_ = m.Event(e.ID, e.EventID, e.Data, e.Timestamp)
	}
	return []int32{}, nil
}
func (m *linuxDBusMenu) AboutToShow(id int32) (bool, *dbus.Error) { return false, nil }
func (m *linuxDBusMenu) AboutToShowGroup(ids []int32) ([]int32, []int32, *dbus.Error) {
	return []int32{}, []int32{}, nil
}

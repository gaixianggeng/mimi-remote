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
}

type linuxTraySnapshot struct {
	Status    agentStatus
	HasStatus bool
	Error     string
	Busy      bool
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
	if s.HasStatus {
		items = append(items,
			linuxMenuItem{ID: 4, Label: "地址：" + s.Status.Endpoint},
			linuxMenuItem{ID: 5, Label: "agentd " + firstNonEmpty(s.Status.ServerVersion, s.Status.Version)},
		)
		if s.Status.NetworkStatus != nil {
			items = append(items, linuxMenuItem{ID: 6, Label: s.Status.NetworkStatus.detailLines()[0]})
		}
		if s.Status.RuntimeStatus != nil {
			for i, runtime := range s.Status.RuntimeStatus.Runtimes {
				if !runtime.Enabled {
					continue
				}
				items = append(items, linuxMenuItem{ID: int32(20 + i), Label: fmt.Sprintf("%s：%s", runtime.Title, runtime.State)})
			}
			if s.Status.RuntimeStatus.Stale || s.Status.RuntimeStatus.Refreshing {
				items = append(items, linuxMenuItem{ID: 7, Label: "Runtime 状态正在刷新或已过期"})
			}
		}
	}
	available := !s.Busy
	fresh := available && s.HasStatus && s.Error == ""
	items = append(items,
		linuxMenuItem{ID: 90, Separator: true},
		linuxMenuItem{ID: 100, Label: "查看状态", Action: "status", Enabled: true},
		linuxMenuItem{ID: 101, Label: "刷新状态", Action: "refresh", Enabled: available},
		linuxMenuItem{ID: 102, Label: "配对设备…", Action: "pair", Enabled: fresh && s.Status.ServiceOK},
		linuxMenuItem{ID: 103, Label: "复制连接地址", Action: "copy", Enabled: s.HasStatus && s.Status.Endpoint != ""},
		linuxMenuItem{ID: 104, Label: "运行诊断…", Action: "doctor", Enabled: available},
		linuxMenuItem{ID: 105, Label: "查看日志…", Action: "logs", Enabled: available},
		linuxMenuItem{ID: 91, Separator: true},
		linuxMenuItem{ID: 106, Label: "启动服务…", Action: "start", Enabled: fresh && !s.Status.ProcessOK},
		linuxMenuItem{ID: 107, Label: "重启服务…", Action: "restart", Enabled: fresh && s.Status.ProcessOK},
		linuxMenuItem{ID: 108, Label: "停止服务…", Action: "stop", Enabled: fresh && s.Status.ProcessOK},
		linuxMenuItem{ID: 92, Separator: true},
		linuxMenuItem{ID: 109, Label: "退出托盘（服务继续运行）", Action: "quit", Enabled: true},
	)
	for i := range items {
		items[i].Label = truncateUTF16Text(redactTrayText(items[i].Label), 150)
	}
	return items
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
				root.Children = append(root.Children, dbus.MakeVariant(linuxMenuLayout{item.ID, menuProperties(item, names), []dbus.Variant{}}))
			}
		}
		return m.revision, root, nil
	}
	for _, item := range m.items {
		if item.ID == parent {
			root.Properties = menuProperties(item, names)
			return m.revision, root, nil
		}
	}
	return 0, root, dbus.MakeFailedError(fmt.Errorf("unknown menu item"))
}
func (m *linuxDBusMenu) GetGroupProperties(ids []int32, names []string) ([]linuxMenuProperties, *dbus.Error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	result := []linuxMenuProperties{}
	for _, item := range m.items {
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
	for _, item := range m.items {
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

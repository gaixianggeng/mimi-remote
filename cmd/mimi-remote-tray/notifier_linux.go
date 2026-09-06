//go:build linux

package main

import (
	"bytes"
	"context"
	_ "embed"
	"image/png"
	"os"
	"path/filepath"
	"time"

	"github.com/godbus/dbus/v5"
	"github.com/godbus/dbus/v5/introspect"
	"github.com/godbus/dbus/v5/prop"
)

const linuxTrayBusName = "io.github.gaixianggeng.MimiRemote.Tray"
const linuxTrayInterface = "io.github.gaixianggeng.MimiRemote.Tray"
const notifierInterface = "org.kde.StatusNotifierItem"
const notifierPath = dbus.ObjectPath("/StatusNotifierItem")
const watcherInterface = "org.kde.StatusNotifierWatcher"

//go:embed assets/mimi.png
var linuxTrayBrandPNG []byte

type trayPixmap struct {
	Width, Height int32
	Data          []byte
}
type trayTooltip struct {
	IconName           string
	Pixmaps            []trayPixmap
	Title, Description string
}
type linuxNotifier struct {
	conn       *dbus.Conn
	properties *prop.Properties
	menu       *linuxDBusMenu
	show       func(string)
	quit       func()
}

func (n *linuxNotifier) Activate(x, y int32) *dbus.Error                    { go n.show("status"); return nil }
func (n *linuxNotifier) SecondaryActivate(x, y int32) *dbus.Error           { return n.Activate(x, y) }
func (n *linuxNotifier) ContextMenu(x, y int32) *dbus.Error                 { return nil }
func (n *linuxNotifier) Scroll(delta int32, orientation string) *dbus.Error { return nil }

type linuxTrayControl struct{ notifier *linuxNotifier }

func (c *linuxTrayControl) Show() *dbus.Error { go c.notifier.show("status"); return nil }
func (c *linuxTrayControl) Quit() *dbus.Error { c.notifier.quit(); return nil }

func newLinuxNotifier(conn *dbus.Conn, dispatch, show func(string), quit func()) (*linuxNotifier, error) {
	n := &linuxNotifier{conn: conn, menu: &linuxDBusMenu{dispatch: dispatch}, show: show, quit: quit}
	n.menu.update(linuxMenuItems(linuxTraySnapshot{}))
	if err := conn.Export(n, notifierPath, notifierInterface); err != nil {
		return nil, err
	}
	if err := conn.Export(&linuxTrayControl{n}, notifierPath, linuxTrayInterface); err != nil {
		return nil, err
	}
	if err := conn.Export(n.menu, trayMenuPath, trayMenuInterface); err != nil {
		return nil, err
	}
	values := map[string]any{
		"Category": "ApplicationStatus", "Id": "mimi-remote", "Title": "Mimi Remote", "Status": "Active",
		"WindowId": uint32(0), "IconName": linuxTrayIconName(linuxTraySnapshot{}), "IconPixmap": linuxTrayPixmap(linuxTraySnapshot{}),
		"IconThemePath":   linuxTrayIconDirectory(),
		"OverlayIconName": "", "OverlayIconPixmap": []trayPixmap{},
		"AttentionIconName": "mimi-remote-attention-symbolic", "AttentionIconPixmap": linuxTrayPixmap(linuxTraySnapshot{}),
		"AttentionMovieName": "", "ItemIsMenu": true, "Menu": trayMenuPath,
		"ToolTip": trayTooltip{"", []trayPixmap{}, "Mimi Remote", "等待服务状态"},
	}
	props := map[string]*prop.Prop{}
	for key, value := range values {
		props[key] = &prop.Prop{Value: value, Emit: prop.EmitTrue}
	}
	var err error
	n.properties, err = prop.Export(conn, notifierPath, prop.Map{notifierInterface: props})
	if err != nil {
		return nil, err
	}
	node := &introspect.Node{Interfaces: []introspect.Interface{
		{Name: notifierInterface, Methods: introspect.Methods(n), Properties: n.properties.Introspection(notifierInterface), Signals: []introspect.Signal{{Name: "NewIcon"}, {Name: "NewToolTip"}, {Name: "NewStatus", Args: []introspect.Arg{{Name: "status", Type: "s"}}}}},
		{Name: linuxTrayInterface, Methods: introspect.Methods(&linuxTrayControl{n})}, prop.IntrospectData,
	}}
	if err := conn.Export(introspect.NewIntrospectable(node), notifierPath, "org.freedesktop.DBus.Introspectable"); err != nil {
		return nil, err
	}
	menuProps, err := prop.Export(conn, trayMenuPath, prop.Map{trayMenuInterface: {
		"Version": {Value: uint32(3)}, "TextDirection": {Value: "ltr"}, "Status": {Value: "normal"}, "IconThemePath": {Value: []string{}},
	}})
	if err != nil {
		return nil, err
	}
	menuNode := &introspect.Node{Interfaces: []introspect.Interface{{Name: trayMenuInterface, Methods: introspect.Methods(n.menu), Properties: menuProps.Introspection(trayMenuInterface), Signals: []introspect.Signal{{Name: "LayoutUpdated", Args: []introspect.Arg{{Type: "u", Name: "revision"}, {Type: "i", Name: "parent"}}}}}, prop.IntrospectData}}
	if err := conn.Export(introspect.NewIntrospectable(menuNode), trayMenuPath, "org.freedesktop.DBus.Introspectable"); err != nil {
		return nil, err
	}
	return n, nil
}
func (n *linuxNotifier) publish(s linuxTraySnapshot) {
	revision := n.menu.update(linuxMenuItems(s))
	n.properties.SetMust(notifierInterface, "IconPixmap", linuxTrayPixmap(s))
	n.properties.SetMust(notifierInterface, "IconName", linuxTrayIconName(s))
	n.properties.SetMust(notifierInterface, "AttentionIconPixmap", linuxTrayPixmap(s))
	state := "Active"
	if s.Error != "" || s.UIError != "" || (s.HasStatus && s.Status.ProcessOK && (!s.Status.ServiceOK || !s.Status.DoctorOK)) {
		state = "NeedsAttention"
	}
	n.properties.SetMust(notifierInterface, "Status", state)
	n.properties.SetMust(notifierInterface, "ToolTip", trayTooltip{"", []trayPixmap{}, "Mimi Remote", redactTrayText(s.title() + "\nTailcat · " + s.tailcatTitle() + "\n" + s.Error + "\n" + s.UIError)})
	_ = n.conn.Emit(notifierPath, notifierInterface+".NewIcon")
	_ = n.conn.Emit(notifierPath, notifierInterface+".NewToolTip")
	_ = n.conn.Emit(notifierPath, notifierInterface+".NewStatus", state)
	_ = n.conn.Emit(trayMenuPath, trayMenuInterface+".LayoutUpdated", revision, int32(0))
}

// A watcher can appear after login or restart independently of the tray. Keep
// ownership of our bus name and register again only when its owner changes.
func (n *linuxNotifier) watch(ctx context.Context) {
	ticker := time.NewTicker(3 * time.Second)
	defer ticker.Stop()
	registeredOwner := ""
	for {
		callCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
		owner := ""
		err := n.conn.BusObject().CallWithContext(callCtx, "org.freedesktop.DBus.GetNameOwner", 0, watcherInterface).Store(&owner)
		if err != nil {
			registeredOwner = ""
		}
		if owner != "" && owner != registeredOwner {
			err = n.conn.Object(watcherInterface, "/StatusNotifierWatcher").CallWithContext(callCtx, watcherInterface+".RegisterStatusNotifierItem", 0, n.conn.Names()[0]).Err
			if err == nil {
				registeredOwner = owner
			}
		}
		cancel()
		select {
		case <-ctx.Done():
			return
		case <-n.conn.Context().Done():
			n.quit()
			return
		case <-ticker.C:
		}
	}
}
func linuxTrayPixmap(s linuxTraySnapshot) []trayPixmap {
	const size = 32
	pixels := make([]byte, size*size*4)
	brand, err := png.Decode(bytes.NewReader(linuxTrayBrandPNG))
	for y := 0; y < size; y++ {
		for x := 0; x < size; x++ {
			offset := (y*size + x) * 4
			// ARGB32, network byte order, as required by StatusNotifierItem.
			if err == nil && x >= 3 && x < 29 && y >= 7 && y < 25 {
				_, _, _, alpha := brand.At((x-3)*brand.Bounds().Dx()/26, (y-7)*brand.Bounds().Dy()/18).RGBA()
				pixels[offset] = byte(alpha >> 8)
				for c := 1; c < 4; c++ {
					pixels[offset+c] = 220
				}
			}
		}
	}
	return []trayPixmap{{size, size, pixels}}
}

func linuxTrayIconName(s linuxTraySnapshot) string {
	if s.Error != "" || s.UIError != "" || !s.HasStatus || (s.Status.ProcessOK && (!s.Status.ServiceOK || !s.Status.DoctorOK)) {
		return "mimi-remote-attention-symbolic"
	}
	if !s.Status.ProcessOK {
		return "mimi-remote-offline-symbolic"
	}
	return "mimi-remote-symbolic"
}

func linuxTrayIconDirectory() string {
	executable, _ := os.Executable()
	return filepath.Clean(filepath.Join(filepath.Dir(executable), "../share/mimi-remote/icons"))
}

func requestLinuxTrayControl(conn *dbus.Conn, action string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	return conn.Object(linuxTrayBusName, notifierPath).CallWithContext(ctx, linuxTrayInterface+"."+action, 0).Err
}

func quitLinuxTray(conn *dbus.Conn) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var owned bool
	if err := conn.BusObject().CallWithContext(ctx, "org.freedesktop.DBus.NameHasOwner", 0, linuxTrayBusName).Store(&owned); err != nil {
		return err
	}
	if !owned {
		return nil
	}
	// Closing the owning bus can race the Quit reply. Confirm name release rather
	// than treating a disappearing connection as an unsuccessful quit.
	_ = requestLinuxTrayControl(conn, "Quit")
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	for {
		if err := conn.BusObject().CallWithContext(ctx, "org.freedesktop.DBus.NameHasOwner", 0, linuxTrayBusName).Store(&owned); err != nil {
			return err
		}
		if !owned {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
	}
}

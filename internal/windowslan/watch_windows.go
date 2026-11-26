//go:build windows

package windowslan

import (
	"sync"
	"sync/atomic"
	"unsafe"

	"golang.org/x/sys/windows"
)

// EvtSubscribe delivers profile and firewall changes without busy polling or
// starting another PowerShell process. Error callbacks invalidate the watcher.
var (
	eventAPI        = windows.NewLazySystemDLL("wevtapi.dll")
	subscribeEvents = eventAPI.NewProc("EvtSubscribe")
	closeEvents     = eventAPI.NewProc("EvtClose")
	nextWatcher     atomic.Uintptr
	watchers        sync.Map
	eventCallback   = windows.NewCallback(func(action, id, _ uintptr) uintptr {
		if cb, ok := watchers.Load(id); ok {
			cb.(*watchRegistration).deliver(action == 0)
		} // EvtSubscribeActionError
		return 0
	})
)

type watchRegistration struct {
	mu      sync.Mutex
	closed  bool
	changed func(bool)
}

func (r *watchRegistration) deliver(lost bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.closed {
		r.changed(lost)
	}
}

func WatchChanges(changed func(lost bool)) (func(), error) {
	id := nextWatcher.Add(1)
	r := &watchRegistration{changed: changed}
	watchers.Store(id, r)
	var handles []uintptr
	stop := func() {
		watchers.Delete(id)
		r.mu.Lock()
		r.closed = true
		r.mu.Unlock()
		for _, h := range handles {
			closeEvents.Call(h)
		}
	}
	for _, channel := range []string{
		"Microsoft-Windows-NetworkProfile/Operational",
		"Microsoft-Windows-Windows Firewall With Advanced Security/Firewall",
	} {
		path, err := windows.UTF16PtrFromString(channel)
		if err != nil {
			stop()
			return nil, err
		}
		// Local session, all future events. The OS owns callback event handles.
		// Strict delivery reports missed records through the error callback.
		const futureEvents, strict = 1, 0x10000
		h, _, err := subscribeEvents.Call(0, 0, uintptr(unsafe.Pointer(path)), 0, 0, id, eventCallback, futureEvents|strict)
		if h == 0 {
			stop()
			return nil, err
		}
		handles = append(handles, h)
	}
	return stop, nil
}

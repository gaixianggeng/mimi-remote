package desktopipc

import "sync"

type State string

const (
	StateDisabled              State = "disabled"
	StateNotInstalled          State = "not_installed"
	StateDesktopNotRunning     State = "desktop_not_running"
	StateConnecting            State = "connecting"
	StateReady                 State = "ready"
	StateUnsupportedBuild      State = "unsupported_build"
	StateSocketUnavailable     State = "socket_unavailable"
	StateProtocolError         State = "protocol_error"
	StateLegacyCleanupRequired State = "legacy_cleanup_required"
)

const (
	TransportDesktopIPC = "desktop_ipc"
	SupportedVersion    = "26.820.60940"
	SupportedBuild      = "7119"
	SupportedProfile    = "desktop-7119"
)

type Status struct {
	Enabled        bool   `json:"enabled"`
	State          State  `json:"state"`
	Transport      string `json:"transport"`
	DesktopVersion string `json:"desktop_version,omitempty"`
	DesktopBuild   string `json:"desktop_build,omitempty"`
	Profile        string `json:"profile,omitempty"`
}

func DisabledStatus() Status {
	return Status{State: StateDisabled, Transport: TransportDesktopIPC}
}

type statusStore struct {
	mu     sync.RWMutex
	status Status
}

func newStatusStore(enabled bool) *statusStore {
	state := StateDisabled
	if enabled {
		state = StateConnecting
	}
	return &statusStore{status: Status{
		Enabled:   enabled,
		State:     state,
		Transport: TransportDesktopIPC,
	}}
}

func (s *statusStore) get() Status {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.status
}

func (s *statusStore) update(update func(*Status)) Status {
	s.mu.Lock()
	defer s.mu.Unlock()
	update(&s.status)
	return s.status
}

package main

import (
	"context"
	"sync"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/networkaccess"
)

func watchLANPolicy(parent context.Context, gate *networkaccess.LANGate, subscribe func(func(bool)) (func(), error)) {
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	changed := make(chan struct{}, 1)
	// Serialize arming with callbacks delivered during EvtSubscribe.
	var state sync.Mutex
	armed := false
	stop, err := subscribe(func(lost bool) {
		state.Lock()
		defer state.Unlock()
		if lost {
			cancel()
		}
		gate.Invalidate(armed && ctx.Err() == nil)
		select {
		case changed <- struct{}{}:
		default:
		}
	})
	if err != nil {
		return
	}
	defer gate.Invalidate(false)
	defer stop()
	state.Lock()
	armed = ctx.Err() == nil
	gate.Invalidate(armed)
	state.Unlock()
	tick := time.NewTicker(time.Minute)
	defer tick.Stop()
	for ctx.Err() == nil {
		gate.Confirm(ctx)
		select {
		case <-ctx.Done():
			return
		case <-changed:
		case <-tick.C:
		}
	}
}

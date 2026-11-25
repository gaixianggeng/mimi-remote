package httpapi

import (
	"context"
	"os"
	"slices"
	"sync"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/setup"
)

// The SDK probe runs frequently. Reuse an unchanged CLI briefly, then check
// all candidates again so installing a newer CLI also refreshes auto selection.
type claudeCodeVersionCache struct {
	discover  func(context.Context, setup.RuntimeRequest) (setup.RuntimeCandidate, error)
	mu        sync.Mutex
	request   setup.RuntimeRequest
	override  string
	checkedAt time.Time
	info      os.FileInfo
	candidate setup.RuntimeCandidate
}

func (c *claudeCodeVersionCache) resolve(req setup.RuntimeRequest) (setup.RuntimeCandidate, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	override := os.Getenv("CLAUDE_BRIDGE_CLAUDE_BIN")
	if c.info != nil && time.Since(c.checkedAt) < time.Minute && c.override == override &&
		c.request.Pin == req.Pin && c.request.MinimumVersion == req.MinimumVersion && slices.Equal(c.request.Environment, req.Environment) {
		if info, err := os.Stat(c.candidate.Path); err == nil && os.SameFile(c.info, info) &&
			info.ModTime().Equal(c.info.ModTime()) && info.Size() == c.info.Size() {
			return c.candidate, nil
		}
	}
	c.info = nil
	discover := c.discover
	if discover == nil {
		discover = setup.ResolveRuntime
	}
	candidate, err := discover(context.Background(), req)
	if err == nil {
		c.info, _ = os.Stat(candidate.Path)
		c.candidate, c.request, c.override, c.checkedAt = candidate, req, override, time.Now()
	}
	return candidate, err
}

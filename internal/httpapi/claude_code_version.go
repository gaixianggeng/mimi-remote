package httpapi

import (
	"context"
	"os"
	"slices"
	"sync"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/cliinspect"
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
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	c.mu.Lock()
	defer c.mu.Unlock()
	override := os.Getenv("CLAUDE_BRIDGE_CLAUDE_BIN")
	if c.info != nil && time.Since(c.checkedAt) < time.Minute && c.override == override &&
		c.request.Pin == req.Pin && c.request.MinimumVersion == req.MinimumVersion && slices.Equal(c.request.Environment, req.Environment) {
		if cachedClaudeFile(ctx, c.candidate.Path, c.info) != nil {
			return c.candidate, nil
		}
	}
	c.info = nil
	discover := c.discover
	if discover == nil {
		discover = setup.ResolveRuntime
	}
	candidate, err := discover(ctx, req)
	if err == nil {
		c.info = cachedClaudeFile(ctx, candidate.Path, nil)
		c.candidate, c.request, c.override, c.checkedAt = candidate, req, override, time.Now()
	}
	return candidate, err
}

// A cache hit can touch the network on Windows, even inside os.SameFile.
func cachedClaudeFile(ctx context.Context, path string, previous os.FileInfo) os.FileInfo {
	ctx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()
	info, _ := cliinspect.Filesystem(ctx, func() (os.FileInfo, error) {
		current, err := os.Stat(path)
		if err != nil {
			return nil, err
		}
		if previous != nil && (!os.SameFile(previous, current) ||
			!previous.ModTime().Equal(current.ModTime()) || previous.Size() != current.Size()) {
			return nil, nil
		}
		return current, nil
	})
	return info
}

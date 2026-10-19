package httpapi

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// gatewayGitCommonDirectory 是全局发现解析 Git common-dir 的唯一入口；测试替换它来
// 模拟慢 Git、卡住或失败的 Git。
var gatewayGitCommonDirectory = resolveGatewayGitCommonDirectory

// resolveGatewayGitCommonDirectory 返回 path 的 Git common-dir。Git 明确回答“不是仓库”时
// 返回空目录和 nil；超时、进程起不来等没有结论的情况返回错误，不能当作“不在仓库”。
func resolveGatewayGitCommonDirectory(ctx context.Context, path string) (string, error) {
	dir, err := gitResolvedDirectoryResult(ctx, path, "--git-common-dir")
	if err != nil && isGitRepositoryMissingError(err) {
		return "", nil
	}
	return dir, err
}

// gitOwnershipMarkerNone 表示目录向上没有任何 .git 标记：确定不在仓库，不必调用 Git。
const gitOwnershipMarkerNone = "none"

const (
	// 指纹覆盖了常见的仓库/Worktree 变化；TTL 只兜底指纹看不到的情况（如仓库内部损坏后修复）。
	gatewayGitOwnershipCacheTTL = 10 * time.Minute
	gatewayGitOwnershipCacheMax = 4096
	// 冷缓存时几十个已登记项目各要跑一次 Git；有界并发把首轮从秒级压到百毫秒级，
	// 又不会一次拉起几十个 git 进程。
	gatewayGitOwnershipParallelism = 8
)

// gatewayGitOwnershipResolveTimeout 是单次后台判定的上限。它独立于调用方的等待预算：
// 调用方等不及时判定继续跑完并写入缓存，客户端重取同一页时直接命中。测试可缩短它。
var gatewayGitOwnershipResolveTimeout = 10 * time.Second

type gatewayGitOwnershipEntry struct {
	marker    string
	commonDir string
	ok        bool
	checkedAt time.Time
}

type gatewayGitOwnershipFlight struct {
	done    chan struct{}
	entry   gatewayGitOwnershipEntry
	settled bool
}

// gatewayGitOwnershipCache 缓存“目录 → Git common-dir”的判定（#789）。每条记录绑定
// 目录向上最近的 .git 标记指纹：Worktree 被删除、.git 文件被改写或仓库被替换时指纹
// 改变，下一次查询重新调用 Git，不会沿用失效的归属。
//
// Git 一律在后台 goroutine 里执行，同一目录与指纹的并发查询合并成一次。调用方只按
// 自己的预算等待，超出预算得到“未判定”，不会阻塞网关读循环。
type gatewayGitOwnershipCache struct {
	mu       sync.Mutex
	entries  map[string]gatewayGitOwnershipEntry
	inflight map[string]*gatewayGitOwnershipFlight
	slots    chan struct{}
}

func (c *gatewayGitOwnershipCache) lookup(path string, marker string, now time.Time) (gatewayGitOwnershipEntry, bool) {
	c.mu.Lock()
	entry, ok := c.entries[path]
	c.mu.Unlock()
	if !ok || entry.marker != marker || now.Sub(entry.checkedAt) >= gatewayGitOwnershipCacheTTL {
		return gatewayGitOwnershipEntry{}, false
	}
	if entry.ok {
		// 仓库被整体删除时 Worktree 的 .git 文件可能还在；common-dir 不存在就重新判定。
		if info, err := os.Stat(entry.commonDir); err != nil || !info.IsDir() {
			return gatewayGitOwnershipEntry{}, false
		}
	}
	return entry, true
}

// resolve 返回 path 在 marker 指纹下的后台判定；已有同一判定在跑时直接复用。
func (c *gatewayGitOwnershipCache) resolve(path string, marker string) *gatewayGitOwnershipFlight {
	key := path + "\x00" + marker
	c.mu.Lock()
	if flight, ok := c.inflight[key]; ok {
		c.mu.Unlock()
		return flight
	}
	if c.inflight == nil {
		c.inflight = map[string]*gatewayGitOwnershipFlight{}
	}
	if c.slots == nil {
		c.slots = make(chan struct{}, gatewayGitOwnershipParallelism)
	}
	flight := &gatewayGitOwnershipFlight{done: make(chan struct{})}
	c.inflight[key] = flight
	slots := c.slots
	c.mu.Unlock()

	go func() {
		slots <- struct{}{}
		ctx, cancel := context.WithTimeout(context.Background(), gatewayGitOwnershipResolveTimeout)
		commonDir, err := gatewayGitCommonDirectory(ctx, path)
		cancel()
		<-slots

		// Git 没给出结论（超时、进程起不来等）时不是“不在仓库”，不能缓存成否定结果。
		settled := err == nil
		entry := gatewayGitOwnershipEntry{marker: marker, commonDir: commonDir, ok: settled && commonDir != "", checkedAt: time.Now()}
		c.mu.Lock()
		if settled {
			if c.entries == nil || len(c.entries) >= gatewayGitOwnershipCacheMax {
				// 与全局 cursor 表一致：容量到顶时整体换代，代价只是下一轮重新查询 Git。
				c.entries = map[string]gatewayGitOwnershipEntry{}
			}
			c.entries[path] = entry
		}
		flight.entry = entry
		flight.settled = settled
		delete(c.inflight, key)
		c.mu.Unlock()
		close(flight.done)
	}()
	return flight
}

// gitOwnershipMarker 返回 path 向上最近的 .git 标记指纹；找不到时为 gitOwnershipMarkerNone。
// .git 目录只取对象身份：提交、加锁会频繁改动目录 mtime，但不会改变仓库归属。
// .git 文件（linked worktree）再带上大小与 mtime，指向别的仓库时一定会变。
func gitOwnershipMarker(path string) string {
	dir := filepath.Clean(path)
	for {
		marker := filepath.Join(dir, ".git")
		if info, err := os.Lstat(marker); err == nil {
			identity, _ := filesystemObjectIdentity(marker)
			if info.IsDir() {
				return fmt.Sprintf("dir:%s:%s", marker, identity)
			}
			return fmt.Sprintf("file:%s:%s:%d:%d", marker, identity, info.Size(), info.ModTime().UnixNano())
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return gitOwnershipMarkerNone
		}
		dir = parent
	}
}

type gatewayGitCommonDirResult struct {
	commonDir string
	ok        bool
	// settled=false 表示在调用方预算内没有结论（Git 慢、卡住或超时）：这既不是
	// “属于仓库”也不是“不属于仓库”，调用方不能据此裁剪或授权。
	settled bool
}

// gatewayGitCommonDirs 解析多个目录的 Git common-dir，结果与 paths 一一对应。
// 缓存命中立即返回；其余目录并行进入后台判定，最多等到 ctx 结束。
func (r *Router) gatewayGitCommonDirs(ctx context.Context, paths []string) []gatewayGitCommonDirResult {
	results := make([]gatewayGitCommonDirResult, len(paths))
	flights := make([]*gatewayGitOwnershipFlight, len(paths))
	now := time.Now()
	for index, path := range paths {
		marker := gitOwnershipMarker(path)
		if marker == gitOwnershipMarkerNone {
			results[index] = gatewayGitCommonDirResult{settled: true}
			continue
		}
		if entry, hit := r.gatewayGitOwnership.lookup(path, marker, now); hit {
			results[index] = gatewayGitCommonDirResult{commonDir: entry.commonDir, ok: entry.ok, settled: true}
			continue
		}
		flights[index] = r.gatewayGitOwnership.resolve(path, marker)
	}
	for index, flight := range flights {
		if flight == nil {
			continue
		}
		select {
		case <-flight.done:
			results[index] = gatewayGitCommonDirResult{
				commonDir: flight.entry.commonDir, ok: flight.entry.ok, settled: flight.settled,
			}
		case <-ctx.Done():
		}
	}
	return results
}

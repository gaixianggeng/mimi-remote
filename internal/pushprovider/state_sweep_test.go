package pushprovider

import (
	"fmt"
	"testing"
	"time"
)

// #915：状态表达到阈值后，清扫按固定节奏进行，不由每个请求各扫一遍全表。

func TestRateLimiterSweepsAtMostOncePerInterval(t *testing.T) {
	limiter := newRateLimiter()
	start := time.Unix(1_790_000_000, 0)
	for i := 0; i < 5000; i++ {
		limiter.allow(fmt.Sprintf("ip:%d", i), start)
	}
	if got := len(limiter.buckets); got != 5000 {
		t.Fatalf("buckets = %d, want all 5000 active keys admitted", got)
	}
	if limiter.sweeps != 1 {
		t.Fatalf("sweeps = %d, want 1 when the table first reaches the threshold", limiter.sweeps)
	}
	for i := 0; i < 1000; i++ {
		limiter.allow("ip:0", start.Add(time.Duration(i)*time.Millisecond))
	}
	if limiter.sweeps != 1 {
		t.Fatalf("sweeps = %d, requests within the interval must not rescan", limiter.sweeps)
	}

	// 过期之后的第一次请求清扫一次，只留下仍在访问的桶。
	later := start.Add(bucketIdleLife + time.Second)
	limiter.allow("ip:0", later)
	if limiter.sweeps != 2 {
		t.Fatalf("sweeps = %d, want a sweep once the interval passed", limiter.sweeps)
	}
	if got := len(limiter.buckets); got != 1 {
		t.Fatalf("buckets = %d, want only the recently used key after the sweep", got)
	}
}

func TestRateLimiterStillLimitsExistingKeysAboveThreshold(t *testing.T) {
	limiter := newRateLimiter()
	now := time.Unix(1_790_000_000, 0)
	for i := 0; i < stateSweepThreshold+10; i++ {
		limiter.allow(fmt.Sprintf("ip:%d", i), now)
	}
	allowed := 0
	for i := 0; i < rateBurst+5; i++ {
		if limiter.allow("ticket:busy", now) {
			allowed++
		}
	}
	if allowed != rateBurst {
		t.Fatalf("allowed = %d, want burst %d", allowed, rateBurst)
	}
}

func TestActivityCoalescerSweepKeepsPendingUpdates(t *testing.T) {
	now := time.Unix(1_790_000_000, 0)
	coalescer := newActivityCoalescer(liveActivityMinInterval, func() time.Time { return now }, func(liveActivityJob) {})
	coalescer.schedule = func(time.Duration, func()) {}
	update := func(status string) liveActivityJob {
		return liveActivityJob{notification: LiveActivityNotification{
			Event:        liveActivityEventUpdate,
			ContentState: LiveActivityContentState{Status: status},
		}}
	}
	for i := 0; i < 5000; i++ {
		coalescer.submit(fmt.Sprintf("activity-%d", i), update(liveActivityStatusRunning))
	}
	// 前 10 个活动在窗口内又来一条，变成待发。
	for i := 0; i < 10; i++ {
		coalescer.submit(fmt.Sprintf("activity-%d", i), update(liveActivityStatusRunning))
	}
	if coalescer.sweeps != 1 {
		t.Fatalf("sweeps = %d, want 1 within the first interval", coalescer.sweeps)
	}

	now = now.Add(stateSweepInterval)
	coalescer.submit("activity-new", update(liveActivityStatusRunning))
	if coalescer.sweeps != 2 {
		t.Fatalf("sweeps = %d, want a sweep after the interval", coalescer.sweeps)
	}
	for i := 0; i < 10; i++ {
		entry := coalescer.entries[fmt.Sprintf("activity-%d", i)]
		if entry == nil || entry.pending == nil {
			t.Fatalf("activity-%d lost its pending update during the sweep", i)
		}
	}
	if got := len(coalescer.entries); got != 11 {
		t.Fatalf("entries = %d, want the 10 pending activities plus the new one", got)
	}
}

func BenchmarkRateLimiterAllowExistingKeyAboveThreshold(b *testing.B) {
	for _, size := range []int{stateSweepThreshold - 1, stateSweepThreshold, 2 * stateSweepThreshold} {
		b.Run(fmt.Sprintf("buckets=%d", size), func(b *testing.B) {
			limiter := newRateLimiter()
			now := time.Unix(1_790_000_000, 0)
			for i := 0; i < size; i++ {
				limiter.allow(fmt.Sprintf("ip:%d", i), now)
			}
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				limiter.allow("ip:0", now)
			}
		})
	}
}

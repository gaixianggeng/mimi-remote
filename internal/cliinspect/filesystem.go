package cliinspect

import "context"

// Go file operations may block in the kernel on a disconnected network mount.
// Limit outstanding system calls across requests and let the caller's deadline
// release the resolver while the kernel finishes the call.
var inspectionSlots = make(chan struct{}, 8)

// Bounded lets discovery move on when a filesystem call or inspection stalls.
func Bounded[T any](ctx context.Context, fn func() (T, error)) (T, error) {
	return withSlots(ctx, inspectionSlots, fn)
}

func withSlots[T any](ctx context.Context, slots chan struct{}, fn func() (T, error)) (T, error) {
	var zero T
	if err := ctx.Err(); err != nil {
		return zero, err
	}
	select {
	case slots <- struct{}{}:
	case <-ctx.Done():
		return zero, ctx.Err()
	}
	type result struct {
		value T
		err   error
	}
	done := make(chan result, 1)
	go func() {
		defer func() { <-slots }()
		value, err := fn()
		done <- result{value, err}
	}()
	select {
	case r := <-done:
		return r.value, r.err
	case <-ctx.Done():
		return zero, ctx.Err()
	}
}

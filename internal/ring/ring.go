package ring

import "sync"

type Buffer struct {
	mu    sync.Mutex
	limit int
	data  []byte
}

func New(limit int) *Buffer {
	if limit <= 0 {
		limit = 128 * 1024
	}
	return &Buffer{limit: limit}
}

func (b *Buffer) Write(p []byte) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if len(p) == 0 {
		return
	}
	if len(p) >= b.limit {
		// 超大输出块本身已经超过窗口时，只复制最后 limit 字节。
		// 这样不会先把旧 buffer 和整块 p 拼成临时大数组，再整体裁剪。
		b.data = append(b.data[:0], p[len(p)-b.limit:]...)
		return
	}
	if len(b.data)+len(p) <= b.limit {
		b.data = append(b.data, p...)
		return
	}

	// 只保留最近输出，避免 iPad 长时间运行后被大日志拖垮。
	// 小块追加超过窗口时，把仍需保留的旧尾部前移，再追加新块，复用已有容量。
	overflow := len(b.data) + len(p) - b.limit
	keep := len(b.data) - overflow
	copy(b.data[:keep], b.data[overflow:])
	b.data = append(b.data[:keep], p...)
}

func (b *Buffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return string(append([]byte(nil), b.data...))
}

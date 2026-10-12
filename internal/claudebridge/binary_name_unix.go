//go:build !windows

package claudebridge

const (
	// BinaryName 是旧 Rust bridge，回退开关打开时使用（保留一个版本周期，#660）。
	BinaryName = "alleycat-claude-bridge"
	// AdapterBinaryName 是基于 Claude Agent SDK 的适配器，#660 起默认使用。
	AdapterBinaryName = "mimi-claude-adapter"
)

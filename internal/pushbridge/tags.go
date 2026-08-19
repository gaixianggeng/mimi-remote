// Package pushbridge 是 agentd 侧的锁屏审批安全层：设备注册、一次性动作句柄
// 状态机，以及调用最小 Provider 的客户端。
//
// 它对 Codex 与 Claude Code 一视同仁：两条 runtime 的反向审批请求走同一套动作
// 句柄与同一组枚举，通知里也只出现枚举与匿名短标签。
//
// 边界：这里既不保存 Prompt、源码、完整命令、文件内容，也不把 agentd 的访问
// Token 交给任何外部服务。用户的允许/拒绝始终由设备直连自己的 agentd 提交。
package pushbridge

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
)

// ApprovalKind 是 Provider 与 iOS 共用的审批类型枚举。新增 runtime 审批方法时
// 必须在这里登记，未登记的方法不会产生推送（fail closed），但前台链路不受影响。
const (
	KindCommand     = "command"
	KindPatch       = "patch"
	KindPermission  = "permission"
	KindUserInput   = "user_input"
	KindElicitation = "elicitation"
)

var approvalKindByMethod = map[string]string{
	"execCommandApproval":                   KindCommand,
	"item/commandExecution/requestApproval": KindCommand,
	"applyPatchApproval":                    KindPatch,
	"item/fileChange/requestApproval":       KindPatch,
	"item/permissions/requestApproval":      KindPermission,
	"item/tool/requestUserInput":            KindUserInput,
	"mcpServer/elicitation/request":         KindElicitation,
}

// ApprovalKindForMethod 把 runtime 的反向请求方法收敛成固定枚举。
func ApprovalKindForMethod(method string) (string, bool) {
	kind, ok := approvalKindByMethod[strings.TrimSpace(method)]
	return kind, ok
}

// ShortTag 生成用于通知展示的匿名短标签。它是加盐摘要的前 4 位大写十六进制：
// 足以让用户区分「哪台 Mac、哪个会话」，又不泄漏主机名、项目名或会话标题。
func ShortTag(salt string, value string) string {
	digest := sha256.Sum256([]byte("mimi-tag:" + salt + ":" + strings.TrimSpace(value)))
	return strings.ToUpper(hex.EncodeToString(digest[:]))[:4]
}

func HostTag(installationID string) string { return ShortTag("host", installationID) }
func SessionTag(threadID string) string    { return ShortTag("session", threadID) }
func ProfileTag(installationID string) string {
	// profile_id 只需要在一次安装内稳定，用于让 App 路由到正确的连接档案。
	digest := sha256.Sum256([]byte("mimi-profile:" + strings.TrimSpace(installationID)))
	return hex.EncodeToString(digest[:])[:16]
}

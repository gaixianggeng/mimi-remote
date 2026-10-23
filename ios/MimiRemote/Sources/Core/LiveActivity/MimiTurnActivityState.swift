import Foundation
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

/// 锁屏 / 灵动岛 Live Activity 的状态（#830）。
///
/// 字段与推送服务 `internal/pushprovider/liveactivity.go` 的 content-state 一一对应：
/// 系统只用默认 Codable 策略解码 APNs 里的 `content-state`，属性名必须是
/// `status`、`runningCount`、`needsYouCount`、`startedAt`、`focusSessionTag`。
/// 这里只有枚举、计数、时间戳与匿名短标签；会话标题由 Widget 扩展按短标签从
/// App Group 缓存在本机查。
///
/// 这个文件同时编译进 Widget 扩展，只允许依赖 Foundation 与 ActivityKit。
enum MimiTurnActivityStatus: String, Codable, Hashable, CaseIterable {
    case running
    case needsYou
    case completed
    case failed

    /// 新版 agentd 可能加入旧 App 不认识的状态；解码失败会让系统丢掉整条更新，
    /// 所以未知值按「运行中」显示，而不是让活动停在旧状态。
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .running
    }

    var isActive: Bool { self == .running || self == .needsYou }
}

struct MimiTurnActivityState: Codable, Hashable {
    var status: MimiTurnActivityStatus
    var runningCount: Int
    var needsYouCount: Int
    /// Unix 秒。推送服务发整数；声明成 Date 时默认策略会按 2001 年参考时间解释。
    var startedAt: Int64
    /// 最需要关注的会话的 16 位短标签，与回复提醒的 `session_tag` 相同。
    var focusSessionTag: String

    init(
        status: MimiTurnActivityStatus,
        runningCount: Int,
        needsYouCount: Int,
        startedAt: Int64,
        focusSessionTag: String
    ) {
        self.status = status
        self.runningCount = max(0, runningCount)
        self.needsYouCount = max(0, needsYouCount)
        self.startedAt = startedAt
        self.focusSessionTag = focusSessionTag
    }

    var startDate: Date { Date(timeIntervalSince1970: TimeInterval(startedAt)) }

    /// 同时有多个会话在跑或等你处理时显示汇总，而不是只显示焦点会话。
    var isMultiSession: Bool { runningCount + needsYouCount > 1 }
}

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
/// 类型名必须与推送服务的 `LiveActivityAttributesType` 完全一致，否则 push-to-start
/// 拉不起活动。`hostTag` 是这台 Mac 的 4 位匿名标签，用来把活动归到正确的连接档案。
struct MimiTurnActivityAttributes: ActivityAttributes {
    typealias ContentState = MimiTurnActivityState

    var hostTag: String
}
#endif

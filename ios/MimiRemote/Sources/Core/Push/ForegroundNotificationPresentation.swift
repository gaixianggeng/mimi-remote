import Foundation
import UserNotifications

/// App 在前台时一条通知怎么呈现（#510）。只作用于 `willPresent`；后台与锁屏完全交给系统。
///
/// - 回复类（会话完成 / 失败 / 中断，agentd 推送与本机运行态通知同等对待）不再弹系统横幅，
///   改由 App 在顶部给一条轻提示，点按跳到对应会话；
/// - 目标会话此刻就在某个窗口里可见时什么都不出；
/// - 审批、补充信息与用户自设的定时提醒有时效，继续走系统横幅和声音；
/// - 类别不确定（旧版已排队的运行态通知、无法解码的载荷）或此刻没有能显示轻提示的前台窗口时，
///   按系统横幅兜底，不能把通知静默丢掉。
///
/// App 不使用角标：APNs payload 与本地通知都不带 badge，所以三种结果都不含 `.badge`。
/// 轻提示只返回 `.list`：进通知中心留底，但不弹横幅、不响铃。
enum ForegroundNotificationPresentation: Equatable {
    case quiet
    case system
    case inApp(ForegroundSessionNotice.Tone, ForegroundSessionNotice.Target)

    var options: UNNotificationPresentationOptions {
        switch self {
        case .quiet:
            // 目标会话就在眼前，结果已经显示在页面里，不需要任何形式的提醒。
            return []
        case .inApp:
            // 不弹横幅、不响铃，但仍写进通知中心：轻提示只有一个位置，几秒内连续收到时
            // 后到的会替换先到的；留在通知中心里的记录保证前一条不会丢，之后也能点开跳转。
            return [.list]
        case .system:
            return [.banner, .sound]
        }
    }

    /// 诊断只记枚举结论，不带任何会话标识。
    var diagnosticOutcome: String {
        switch self {
        case .quiet: return "quiet"
        case .system: return "system"
        case .inApp: return "in_app"
        }
    }
}

/// 前台回复提醒的一条轻提示。所有前台窗口共用同一条，后到的替换先到的。
struct ForegroundSessionNotice: Identifiable, Equatable {
    enum Tone: String, Equatable {
        case completed
        case failed
        case interrupted

        init?(event: LockScreenApprovalNotification.Event) {
            switch event {
            case .completed: self = .completed
            case .failed: self = .failed
            case .interrupted: self = .interrupted
            case .pending, .resolved: return nil
            }
        }

        init?(runtimeKind: SessionRuntimeNotification.Kind) {
            switch runtimeKind {
            case .completed: self = .completed
            case .failed: self = .failed
            case .interrupted: self = .interrupted
            case .approval: return nil
            }
        }
    }

    enum Target: Hashable {
        /// 本机运行态通知：带完整会话路由。
        case route(SessionNotificationRoute)
        /// agentd 推送：只有匿名的电脑标签与会话标签，真正的会话由通知收件箱解析。
        case message(profileTag: String, sessionTag: String)
    }

    let id: UUID
    let requestIdentifier: String
    let tone: Tone
    let target: Target
    let title: String
    let body: String
    /// 点按时原样交回通知点击入口，与点系统横幅走同一条路由链路。
    let userInfo: [AnyHashable: Any]
    /// 负责显示这条提示的 Scene。多窗口时只在一个窗口出现，避免 VoiceOver 重复播报；
    /// nil 表示任一前台窗口都可显示。
    let hostSceneID: UUID?

    init(
        id: UUID = UUID(),
        requestIdentifier: String,
        tone: Tone,
        target: Target,
        title: String,
        subtitle: String = "",
        body: String,
        userInfo: [AnyHashable: Any],
        hostSceneID: UUID? = nil
    ) {
        // 远程推送经通知扩展改写后标题是会话名、正文是结果；未改写时标题是通用文案。
        // 卡片只有两行：标题为空时依次顺延到副标题、正文，保证第一行永远有字。
        let lines = [title, subtitle, body]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.id = id
        self.requestIdentifier = requestIdentifier
        self.tone = tone
        self.target = target
        self.title = lines.first ?? ""
        // 正文优先；没有正文时才用副标题补第二行。
        self.body = lines.count > 1 ? lines[lines.count - 1] : ""
        self.userInfo = userInfo
        self.hostSceneID = hostSceneID
    }

    static func == (lhs: ForegroundSessionNotice, rhs: ForegroundSessionNotice) -> Bool {
        lhs.id == rhs.id
    }
}

extension SessionRuntimeNotification.Kind {
    /// 运行态通知的类别写进 userInfo，前台呈现不再靠解析通知 ID 字符串区分审批与回复。
    static let notificationUserInfoKey = "mimi.runtime.kind"

    /// 旧版已排队的通知没有这个键，返回 nil 由调用方按系统横幅兜底。
    init?(notificationUserInfo userInfo: [AnyHashable: Any]) {
        guard let raw = userInfo[Self.notificationUserInfoKey] as? String else { return nil }
        self.init(rawValue: raw)
    }
}

extension SessionRuntimeNotification {
    func notificationUserInfo(route: SessionNotificationRoute) -> [AnyHashable: Any] {
        var userInfo = route.userInfo
        userInfo[Kind.notificationUserInfoKey] = kind.rawValue
        return userInfo
    }
}

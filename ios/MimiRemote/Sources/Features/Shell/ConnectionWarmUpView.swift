import SwiftUI

/// 首次连接一台电脑时的过渡界面。
///
/// 冷启动和切换电脑都要先建隧道、再等 agentd 网关的上游就绪，这个窗口内的失败是过程
/// 而不是结论。整屏只保留**一处**"正在进行"的表达：正中的加载圆环。顶栏设备入口在这
/// 段时间不再叠第二枚转圈（`HostSwitcherMenu(suppressesProgressBadge:)`），否则同一件
/// 事被说两遍，用户读到的是"两个地方都在转"，而不是"正在连接这台电脑"。
///
/// 这里也不再画内容骨架。骨架预告的是版面，可一旦它和一枚转圈、一枚顶栏徽标同时出现，
/// 整屏就散成三处闪动；连接过渡真正要回答的只有一句话——现在在连哪台电脑。
///
/// 圆环中心对准屏幕纵向正中。调用方应把它铺在整页上（而不是塞进列表行），
/// 会话页与工作区页的落点才会一致，切换 Tab 时圆环不跳。
struct ConnectionWarmUpView: View {
    @EnvironmentObject private var appStore: AppStore

    /// 标题。默认写成"正在连接 <电脑名>"，调用方可替换成本页面更贴切的说法。
    var headline: String?
    /// 说明文案。默认解释"通道正在建立"，调用方可替换成本页面更贴切的说明。
    var message: String?

    var body: some View {
        LoadingStateView(title: resolvedHeadline, message: resolvedMessage)
            .accessibilityIdentifier("connection.warmUp")
    }

    /// 连接目标写在标题里。用户同时配对多台电脑时，"正在连接" 本身并不足以说明发生了什么。
    private var resolvedHeadline: String {
        if let headline, !headline.isEmpty {
            return headline
        }
        guard let displayName = appStore.activeConnectionProfile?.displayName,
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return L10n.text("ui.connecting_to_your_mac")
        }
        return L10n.format("ui.connecting_to_value", displayName)
    }

    private var resolvedMessage: String {
        message ?? L10n.text("ui.a_secure_channel_is_being_established_content_appears")
    }
}

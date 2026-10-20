import ActivityKit
import SwiftUI
import WidgetKit

/// 锁屏与灵动岛上的回合进度（#830）。推送只带枚举、计数、开始时间与匿名短标签；
/// 标题在渲染时从 App Group 的通知标题缓存按短标签在本机查，查不到显示通用文案。
struct MimiTurnLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MimiTurnActivityAttributes.self) { context in
            let presentation = Self.presentation(context)
            MimiTurnActivityLockScreenView(
                presentation: presentation,
                isStale: context.isStale,
                staleText: Self.localize("live_activity.stale")
            )
            .widgetURL(presentation.deepLink)
        } dynamicIsland: { context in
            let presentation = Self.presentation(context)
            let activeCount = context.state.runningCount + context.state.needsYouCount
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    MimiTurnActivityExpandedLeadingView(presentation: presentation)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    MimiTurnActivityExpandedTrailingView(presentation: presentation)
                }
                DynamicIslandExpandedRegion(.center) {
                    MimiTurnActivityExpandedCenterView(presentation: presentation)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    MimiTurnActivityExpandedBottomView(
                        presentation: presentation,
                        isStale: context.isStale,
                        staleText: Self.localize("live_activity.stale")
                    )
                }
            } compactLeading: {
                MimiTurnActivityCompactLeadingView(presentation: presentation)
            } compactTrailing: {
                MimiTurnActivityCompactTrailingView(presentation: presentation, activeCount: activeCount)
            } minimal: {
                MimiTurnActivityMinimalView(presentation: presentation)
            }
            .widgetURL(presentation.deepLink)
            .keylineTint(MimiTurnActivityStyle.tint(presentation.status))
        }
    }

    private static func presentation(
        _ context: ActivityViewContext<MimiTurnActivityAttributes>
    ) -> MimiTurnActivityPresentation {
        MimiTurnActivityPresentation.make(
            hostTag: context.attributes.hostTag,
            state: context.state,
            cache: NotificationTitleCache.load(),
            localize: localize
        )
    }

    private static func localize(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "Localizable")
    }
}

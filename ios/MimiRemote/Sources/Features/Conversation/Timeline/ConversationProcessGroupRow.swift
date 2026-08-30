import SwiftUI

struct ConversationWorkGroupRow<Content: View>: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorScheme) private var colorScheme

    let group: ConversationWorkGroup
    let layout: ConversationLayout
    let isExpanded: Bool
    let toggleGroup: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: toggleGroup) {
                    header
                }
                .buttonStyle(.plain)
                .accessibilityLabel(group.title())
                .accessibilityValue(accessibilityValue)
                .accessibilityHint(
                    isExpanded
                        ? L10n.text("ui.collapse_this_stage_of_activities")
                        : L10n.text("ui.expand_this_stage_of_activities")
                )

                if isExpanded {
                    HStack(alignment: .top, spacing: 0) {
                        Rectangle()
                            .fill(tokens.border.opacity(0.9))
                            .frame(width: 2)
                            .padding(.leading, 6)

                        VStack(alignment: .leading, spacing: 2) {
                            content()
                        }
                        .padding(.leading, 18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .transition(groupTransition)
                }
            }
            .frame(maxWidth: layout.assistantBubbleMaxWidth, alignment: .leading)

            Spacer(minLength: layout.messageSideSpacer)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            if group.status != .completed {
                statusMarker
            }

            HStack(alignment: .center, spacing: 6) {
                Group {
                    if group.status == .running {
                        // 只让运行中的标题按秒刷新；终态行保持静态，避免历史 List 无意义重绘。
                        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(group.title(at: context.date))
                        }
                    } else {
                        Text(group.title())
                    }
                }
                .font(themeStore.uiFont(size: 14, weight: .medium))
                .foregroundStyle(headerTint)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

                Text(activityCountLabel)
                    .font(themeStore.uiFont(.caption2, weight: .medium))
                    .foregroundStyle(tokens.secondaryText.opacity(0.82))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Image(systemName: "chevron.right")
                    .font(themeStore.uiFont(.caption2, weight: .semibold))
                    .foregroundStyle(tokens.secondaryText.opacity(0.76))
                    .frame(width: 18, height: 18)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }

            Spacer(minLength: 0)
        }
        // 完成态移除信息量有限的图标，活动数量和 chevron 收紧到标题旁；
        // Button 仍保留至少 44pt 高度和整行 contentShape，触控与辅助功能命中区不变。
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusMarker: some View {
        switch group.status {
        case .running:
            ProgressView()
                .controlSize(.mini)
                .tint(tokens.accent)
                .frame(width: 14, height: 18)
        case .completed:
            EmptyView()
        case .interrupted:
            Image(systemName: "stop.circle.fill")
                .font(themeStore.uiFont(size: 11, weight: .semibold))
                .foregroundStyle(tokens.secondaryText)
                .frame(width: 14, height: 18)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(themeStore.uiFont(size: 11, weight: .semibold))
                .foregroundStyle(Color.red)
                .frame(width: 14, height: 18)
        }
    }

    private var groupTransition: AnyTransition {
        accessibilityReduceMotion
            ? .opacity
            : .opacity.combined(with: .move(edge: .top))
    }

    private var accessibilityValue: String {
        let state = isExpanded ? L10n.text("ui.expanded") : L10n.text("ui.collected")
        return L10n.format(
            "ui.value_contains_value",
            state,
            L10n.plural("ui.activities_count", count: group.activityCount)
        )
    }

    private var activityCountLabel: String {
        L10n.plural("ui.activities_count", count: group.activityCount)
    }

    private var headerTint: Color {
        group.status == .failed ? .red : tokens.secondaryText
    }

    private var tokens: ThemeTokens {
        themeStore.tokens(for: colorScheme)
    }
}

struct ConversationProcessGroupRow: View, Equatable {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorScheme) private var colorScheme

    let group: ConversationProcessGroup
    let layout: ConversationLayout
    let isExpanded: Bool
    let expandedActivityIDs: Set<String>
    let toggleGroup: () -> Void
    let toggleActivity: (ConversationMessage) -> Void
    let recordAnchorGeometry: ([UUID], CGRect) -> Void

    init(
        group: ConversationProcessGroup,
        layout: ConversationLayout,
        isExpanded: Bool,
        expandedActivityIDs: Set<String>,
        toggleGroup: @escaping () -> Void,
        toggleActivity: @escaping (ConversationMessage) -> Void,
        recordAnchorGeometry: @escaping ([UUID], CGRect) -> Void = { _, _ in }
    ) {
        self.group = group
        self.layout = layout
        self.isExpanded = isExpanded
        self.expandedActivityIDs = expandedActivityIDs
        self.toggleGroup = toggleGroup
        self.toggleActivity = toggleActivity
        self.recordAnchorGeometry = recordAnchorGeometry
    }

    static func == (lhs: ConversationProcessGroupRow, rhs: ConversationProcessGroupRow) -> Bool {
        guard lhs.group.id == rhs.group.id,
              lhs.group.title == rhs.group.title,
              lhs.group.status == rhs.group.status,
              lhs.group.activities.count == rhs.group.activities.count,
              lhs.group.failedCount == rhs.group.failedCount,
              lhs.layout == rhs.layout,
              lhs.isExpanded == rhs.isExpanded,
              lhs.expandedActivityIDs == rhs.expandedActivityIDs
        else {
            return false
        }
        return !lhs.isExpanded || lhs.group.activities == rhs.group.activities
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Button(action: toggleGroup) {
                    header
                }
                .buttonStyle(.plain)
                .accessibilityLabel(summaryText)
                .accessibilityValue(accessibilityValue)
                .accessibilityHint(isExpanded ? L10n.text("ui.collapse_this_stage_of_activities") : L10n.text("ui.expand_this_stage_of_activities"))

                if isExpanded {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(group.activities) { message in
                            ConversationActivityRow(
                                message: message,
                                layout: layout,
                                isExpanded: expandedActivityIDs.contains(
                                    ConversationTimelineItem.activityID(for: message)
                                ),
                                toggle: { toggleActivity(message) }
                            )
                            .equatable()
                            .padding(.leading, 20)
                            .modifier(ConversationHistoryAnchorGeometryModifier(
                                isEnabled: true,
                                messageIDs: [message.id],
                                action: recordAnchorGeometry
                            ))
                        }
                    }
                    .transition(activityTransition)
                }
            }
            .frame(maxWidth: layout.assistantBubbleMaxWidth, alignment: .leading)

            Spacer(minLength: layout.messageSideSpacer)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .modifier(ConversationHistoryAnchorGeometryModifier(
            isEnabled: !isExpanded,
            messageIDs: [group.header.id] + group.activities.map(\.id),
            action: recordAnchorGeometry
        ))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            if group.status != .completed {
                statusMarker
            }

            HStack(alignment: .center, spacing: 6) {
                Text(summaryText)
                    .font(themeStore.uiFont(size: 14, weight: .medium))
                    .foregroundStyle(headerTint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Text(activityCountLabel)
                    .font(themeStore.uiFont(.caption2, weight: .medium))
                    .foregroundStyle(tokens.secondaryText.opacity(0.82))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Image(systemName: "chevron.right")
                    .font(themeStore.uiFont(.caption2, weight: .semibold))
                    .foregroundStyle(tokens.secondaryText.opacity(0.76))
                    .frame(width: 18, height: 18)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }

            Spacer(minLength: 0)
        }
        // 完成态不再重复展示没有状态信息的图标，数量和 chevron 直接贴近标题；
        // Button 仍保留 44pt 以上整行命中区，运行/失败/中断标记继续保留。
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusMarker: some View {
        switch group.status {
        case .running:
            ProgressView()
                .controlSize(.mini)
                .tint(tokens.accent)
                .frame(width: 14, height: 18)
        case .completed:
            EmptyView()
        case .interrupted:
            Image(systemName: "stop.circle.fill")
                .font(themeStore.uiFont(size: 11, weight: .semibold))
                .foregroundStyle(tokens.secondaryText)
                .frame(width: 14, height: 18)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(themeStore.uiFont(size: 11, weight: .semibold))
                .foregroundStyle(Color.red)
                .frame(width: 14, height: 18)
        }
    }

    private var activityTransition: AnyTransition {
        accessibilityReduceMotion
            ? .opacity
            : .opacity.combined(with: .move(edge: .top))
    }

    private var accessibilityValue: String {
        let state = isExpanded ? L10n.text("ui.expanded") : L10n.text("ui.collected")
        return L10n.format(
            "ui.value_contains_value",
            state,
            L10n.plural("ui.activities_count", count: group.activities.count)
        )
    }

    private var summaryText: String {
        [group.title, group.failureDetail]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var activityCountLabel: String {
        L10n.plural("ui.activities_count", count: group.activities.count)
    }

    private var headerTint: Color {
        group.status == .failed ? .red : tokens.secondaryText
    }

    private var tokens: ThemeTokens {
        themeStore.tokens(for: colorScheme)
    }
}

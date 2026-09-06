import SwiftUI

struct MessageRow: View, Equatable {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let message: ConversationMessage
    let themeVersion: Int
    let layout: ConversationLayout
    let showsActiveDeliveryStatus: Bool
    let showsCrossSessionOrigin: Bool
    let skills: [SkillCapability]
    let retry: (ConversationMessage) -> Void
    let stop: () -> Void
    let previewFile: (String) async throws -> URL

    // 只有内容 fingerprint / 状态变化时才重绘；长消息内容本身不参与这里的逐行比较。
    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message.id == rhs.message.id
            && lhs.message.role == rhs.message.role
            && lhs.message.kind == rhs.message.kind
            && lhs.message.sendStatus == rhs.message.sendStatus
            && lhs.message.revision == rhs.message.revision
            && lhs.message.userDelivery == rhs.message.userDelivery
            && lhs.message.createdAt == rhs.message.createdAt
            && lhs.message.updatedAt == rhs.message.updatedAt
            && lhs.message.renderFingerprint == rhs.message.renderFingerprint
            && lhs.message.turnPayload == rhs.message.turnPayload
            && lhs.message.activityPayload == rhs.message.activityPayload
            && lhs.themeVersion == rhs.themeVersion
            && lhs.layout == rhs.layout
            && lhs.showsActiveDeliveryStatus == rhs.showsActiveDeliveryStatus
            && lhs.showsCrossSessionOrigin == rhs.showsCrossSessionOrigin
            && lhs.skills == rhs.skills
    }

    var body: some View {
        Group {
            switch message.role {
            case .user:
                userRow
            case .assistant:
                assistantRow
            case .system:
                systemRow
            }
        }
        .frame(maxWidth: .infinity, alignment: rowAlignment)
    }

    private var userRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: layout.messageSideSpacer)
            VStack(alignment: .trailing, spacing: 3) {
                if showsCrossSessionOrigin {
                    crossSessionOriginBadge
                }
                ConversationMessageContent(
                    message: message,
                    layout: layout,
                    skills: skills,
                    retry: retry,
                    stop: stop,
                    previewFile: previewFile
                )
                statusCaption
            }
        }
    }

    private var crossSessionOriginBadge: some View {
        Label(L10n.text("ui.created_from_another_conversation"), systemImage: "arrow.triangle.branch")
            .font(themeStore.uiFont(.caption2, weight: .semibold))
            .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                themeStore.tokens(for: colorScheme).selectionFill,
                in: Capsule(style: .continuous)
            )
            .accessibilityElement(children: .combine)
    }

    private var assistantRow: some View {
        HStack(spacing: 0) {
            if message.kind == .commentary {
                ConversationCommentaryRow(message: message, layout: layout, stop: stop)
            } else {
                ConversationMessageContent(
                    message: message,
                    layout: layout,
                    skills: skills,
                    retry: retry,
                    stop: stop,
                    previewFile: previewFile
                )
            }
            Spacer(minLength: layout.messageSideSpacer)
        }
    }

    private var systemRow: some View {
        Group {
            if isCenteredSystemNotice {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    SystemNotice(message: message, layout: layout)
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 0) {
                    RuntimeSummaryCard(message: message, layout: layout)
                    Spacer(minLength: layout.messageSideSpacer)
                }
            }
        }
    }

    private var isCenteredSystemNotice: Bool {
        message.kind == .message
    }

    // 状态以气泡下方的小字呈现（贴右），比浮在一旁的图标更直观，也避开了气泡定宽框的定位问题。
    @ViewBuilder
    private var statusCaption: some View {
        switch message.sendStatus {
        case .failed:
            Text(L10n.text("ui.sending_failed"))
                .font(themeStore.uiFont(.caption2))
                .foregroundStyle(.red)
        case .sending:
            deliveryCaption(sendingDeliveryCaption)
        case .uncertain:
            deliveryCaption(L10n.text("ui.sending_result_pending_confirmation"))
        case .sent:
            if message.userDelivery == .injected {
                deliveryCaption(L10n.text("ui.conversation_guided"))
            } else if showsActiveDeliveryStatus {
                deliveryCaption(L10n.text("ui.sent_waiting_for_reply"))
            }
        case .confirmed:
            if message.userDelivery == .injected {
                deliveryCaption(L10n.text("ui.conversation_guided"))
            }
        case .local:
            deliveryCaption(message.userDelivery == .queued ? L10n.text("ui.queued_waiting_for_the_current_reply_to_be") : L10n.text("ui.to_be_sent"))
        }
    }

    private var sendingDeliveryCaption: String {
        switch message.userDelivery {
        case .queued:
            return L10n.text("ui.queuing_to_send")
        case .guided, .injected:
            return L10n.text("ui.guide_is_being_sent")
        case nil:
            return L10n.text("ui.sending")
        }
    }

    private func deliveryCaption(_ text: String) -> some View {
        Text(text)
            .font(themeStore.uiFont(.caption2))
            .foregroundStyle(themeStore.tokens(for: colorScheme).secondaryText)
    }

    private var rowAlignment: Alignment {
        switch message.role {
        case .user:
            return .trailing
        case .assistant:
            return .leading
        case .system:
            return isCenteredSystemNotice ? .center : .leading
        }
    }
}

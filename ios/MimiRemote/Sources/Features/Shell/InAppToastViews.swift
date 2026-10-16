import SwiftUI
import UIKit

/// App 内轻提示的通用内容（#508）。
///
/// 一条提示 = 标题 + 可选副文案 + 可选按钮 / 整条点击动作 + 可选技术详情。
/// 宿主（`View.inAppToast`）负责浮层位置、自动收起、轻扫关闭与 VoiceOver 播报；
/// 调用方只描述内容。操作反馈（`OperationFeedback`）与前台回复提醒（#510）共用这一套，
/// 不各自造一份浮层。
struct InAppToast: Identifiable, Equatable {
    enum Style: Equatable {
        case info
        case success
        case failure
        /// 进行中的状态（例如自动重连），用中性样式和进度指示，不冠以「错误」。
        case progress
    }

    struct Action {
        let title: String
        let systemImage: String?
        let perform: @MainActor () -> Void

        init(title: String, systemImage: String? = nil, perform: @escaping @MainActor () -> Void) {
            self.title = title
            self.systemImage = systemImage
            self.perform = perform
        }
    }

    let id: AnyHashable
    let style: Style
    let title: String
    let subtitle: String?
    /// 原始技术描述，只在用户展开「显示详情」后出现，并可复制给支持人员。
    let technicalDetail: String?
    let systemImage: String?
    let action: Action?
    /// 点击提示正文时执行，例如跳到对应会话。为 nil 时正文不可点击。
    let tapAction: (@MainActor () -> Void)?
    /// 自动收起时长；nil 使用按样式给出的默认值。
    let duration: TimeInterval?

    init(
        id: AnyHashable,
        style: Style,
        title: String,
        subtitle: String? = nil,
        technicalDetail: String? = nil,
        systemImage: String? = nil,
        action: Action? = nil,
        tapAction: (@MainActor () -> Void)? = nil,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.style = style
        self.title = title
        self.subtitle = subtitle
        self.technicalDetail = technicalDetail
        self.systemImage = systemImage
        self.action = action
        self.tapAction = tapAction
        self.duration = duration
    }

    /// 失败需要更长的阅读时间，带按钮的再多留一些；VoiceOver 打开时整体加倍，
    /// 避免播报还没读完提示就消失。
    func displayDuration(voiceOverRunning: Bool) -> TimeInterval {
        let base: TimeInterval
        if let duration {
            base = duration
        } else {
            switch style {
            case .info, .success:
                base = 3.5
            case .progress:
                base = 5
            case .failure:
                base = action == nil ? 6 : 10
            }
        }
        return voiceOverRunning ? base * 2 : base
    }

    var accessibilityAnnouncement: String {
        [title, subtitle].compactMap { $0 }.joined(separator: "\n")
    }

    static func == (lhs: InAppToast, rhs: InAppToast) -> Bool {
        lhs.id == rhs.id
            && lhs.style == rhs.style
            && lhs.title == rhs.title
            && lhs.subtitle == rhs.subtitle
            && lhs.technicalDetail == rhs.technicalDetail
            && lhs.action?.title == rhs.action?.title
            && (lhs.tapAction == nil) == (rhs.tapAction == nil)
    }
}

extension InAppToast {
    init(feedback: OperationFeedback, onRetry: @escaping @MainActor (OperationFeedback) -> Void) {
        self.init(
            id: feedback.id,
            style: feedback.kind == .failure ? .failure : .info,
            title: feedback.message,
            technicalDetail: feedback.technicalDetail,
            action: feedback.retry.map { retry in
                Action(title: retry.title, systemImage: "arrow.clockwise") { onRetry(feedback) }
            }
        )
    }
}

extension View {
    /// 在当前视图顶部挂载 App 内轻提示。`toast` 变为 nil 或换成另一条时浮层随之更新；
    /// 自动收起、轻扫或点关闭后调用 `onDismiss`，由数据源清掉对应提示。
    func inAppToast(_ toast: InAppToast?, onDismiss: @escaping (AnyHashable) -> Void) -> some View {
        modifier(InAppToastHost(toast: toast, onDismiss: onDismiss))
    }
}

private struct InAppToastHost: ViewModifier {
    let toast: InAppToast?
    let onDismiss: (AnyHashable) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.inAppNoticePlacement) private var placement
    @State private var showsDetail = false
    /// 提示顶边的全局界线（导航栏、页面常驻卡片的下沿）。只在提示出现、宿主尺寸或常驻区域
    /// 变化时重新测量：宿主随 SessionStore 的每次发布重算，不能每次都遍历窗口。
    @State private var boundaryMeasurement: BoundaryMeasurement?

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            GeometryReader { proxy in
                let hostFrame = proxy.frame(in: .global)
                toastLayer(hostMinY: hostFrame.minY)
                    .onChange(
                        of: PlacementInputs(
                            toastID: toast?.id,
                            hostFrame: hostFrame,
                            protectedRegionBottom: placement?.protectedRegionBottom
                        ),
                        initial: true
                    ) { _, inputs in
                        boundaryMeasurement = inputs.toastID.map {
                            BoundaryMeasurement(toastID: $0, boundary: placement?.topBoundary())
                        }
                    }
            }
        }
    }

    private struct BoundaryMeasurement {
        let toastID: AnyHashable
        let boundary: CGFloat?
    }

    private struct PlacementInputs: Equatable {
        let toastID: AnyHashable?
        let hostFrame: CGRect
        let protectedRegionBottom: CGFloat?
    }

    private func toastLayer(hostMinY: CGFloat) -> some View {
        ZStack {
            if let toast {
                InAppToastCard(toast: toast, showsDetail: $showsDetail, onDismiss: { onDismiss(toast.id) })
                    .padding(.horizontal, 16)
                    .padding(
                        .top,
                        InAppNoticePlacement.toastTopPadding(
                            boundary: topBoundary(for: toast),
                            hostMinY: hostMinY
                        )
                    )
                    .frame(maxWidth: 560)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .top).combined(with: .opacity)
                    )
                    .id(toast.id)
                    .task(id: toast.id) {
                        showsDetail = false
                        AccessibilityNotification.Announcement(toast.accessibilityAnnouncement).post()
                        await autoDismiss(toast)
                    }
            }
        }
        // GeometryReader 把子视图放在左上角；提示仍按原来的方式水平居中。
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.28), value: toast?.id)
    }

    /// 新提示出现的这一帧 onChange 还没跑，直接量一次，避免先落在导航栏上再跳下来。
    private func topBoundary(for toast: InAppToast) -> CGFloat? {
        if let boundaryMeasurement, boundaryMeasurement.toastID == toast.id {
            return boundaryMeasurement.boundary
        }
        return placement?.topBoundary()
    }

    private func autoDismiss(_ toast: InAppToast) async {
        let duration = toast.displayDuration(voiceOverRunning: voiceOverEnabled)
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        // 用户展开详情说明正在阅读，不在阅读中途收走；收起详情后由下一次交互或关闭按钮结束。
        guard !Task.isCancelled, !showsDetail else {
            return
        }
        onDismiss(toast.id)
    }
}

/// 提示卡片本身。宿主负责位置与生命周期；单独暴露给快照测试和需要内嵌展示的页面。
struct InAppToastCard: View {
    let toast: InAppToast
    @Binding var showsDetail: Bool
    let onDismiss: () -> Void

    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                FeedbackStatusIcon(style: toast.style, systemImage: toast.systemImage, tokens: tokens)
                messageStack(tokens: tokens)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard let tapAction = toast.tapAction else { return }
                        onDismiss()
                        tapAction()
                    }
                    .accessibilityAddTraits(toast.tapAction == nil ? [] : .isButton)
                closeButton(tokens: tokens)
            }
            if toast.action != nil || toast.technicalDetail != nil {
                HStack(spacing: 8) {
                    if let action = toast.action {
                        Button {
                            onDismiss()
                            action.perform()
                        } label: {
                            if let systemImage = action.systemImage {
                                Label(action.title, systemImage: systemImage)
                            } else {
                                Text(action.title)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(tokens.primaryActionForeground)
                        .controlSize(.small)
                    }
                    if toast.technicalDetail != nil {
                        TechnicalDetailToggle(isExpanded: $showsDetail)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 32)
            }
            if showsDetail, let detail = toast.technicalDetail {
                TechnicalDetailPanel(detail: detail)
                    .padding(.leading, 32)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            // 浮在任意正文之上，用实色底板保证对比度；阴影只挂在底板上，不能逐个落到文字上。
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tokens.elevatedSurface)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.12), radius: 14, y: 6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(borderColor(tokens: tokens), lineWidth: 1)
        }
        .gesture(
            DragGesture(minimumDistance: 12).onEnded { value in
                // 向上轻扫收起，与系统通知横幅的手势一致。
                if value.translation.height < -16 {
                    onDismiss()
                }
            },
            // 详情展开后让位给详情里的滚动，避免上滑阅读时误把提示收走。
            including: showsDetail ? .subviews : .all
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inAppToast")
    }

    private func messageStack(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(toast.title)
                .font(themeStore.uiFont(.subheadline, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = toast.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func closeButton(tokens: ThemeTokens) -> some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tokens.secondaryText)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text("ui.close"))
        .accessibilityIdentifier("inAppToast.close")
    }

    private func borderColor(tokens: ThemeTokens) -> Color {
        switch toast.style {
        case .failure:
            return Color.red.opacity(0.35)
        case .info, .success, .progress:
            return tokens.border
        }
    }
}

/// 页面内常驻卡片的语气：决定图标和描边颜色。
enum InlineNoticeTone: Equatable {
    case neutral
    case warning
    case failure
    /// 进行中的状态（加载、自动重连），图标换成进度指示。
    case progress
}

/// 页面内的常驻提示卡片（#738）。
///
/// 与 App 内轻提示（`InAppToastCard`，前台回复提醒用的也是它）同一套版式：图标列、粗体标题加一行
/// 说明、右上角关闭、按钮排在说明下方。区别只在于它留在内容流里，不自动收起、不加投影。
/// 会话页顶部的缩略历史、额度、错误三张卡片都用它；需要用户操作或表示持续状态的提示不再各画一套。
struct InlineNoticeCard<Actions: View>: View {
    let tone: InlineNoticeTone
    let systemImage: String?
    let title: String
    let subtitle: String?
    let technicalDetail: String?
    let hasActions: Bool
    let onClose: (() -> Void)?
    let closeAccessibilityIdentifier: String
    let actions: () -> Actions

    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsDetail = false

    init(
        tone: InlineNoticeTone,
        systemImage: String? = nil,
        title: String,
        subtitle: String? = nil,
        technicalDetail: String? = nil,
        hasActions: Bool = true,
        onClose: (() -> Void)? = nil,
        closeAccessibilityIdentifier: String = "inlineNotice.close",
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.tone = tone
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        self.technicalDetail = technicalDetail
        self.hasActions = hasActions
        self.onClose = onClose
        self.closeAccessibilityIdentifier = closeAccessibilityIdentifier
        self.actions = actions
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                FeedbackStatusIcon(style: iconStyle, systemImage: systemImage, tokens: tokens, tintOverride: iconTint(tokens))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(themeStore.uiFont(.subheadline, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(themeStore.uiFont(.caption))
                            .foregroundStyle(tokens.secondaryText)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .frame(maxWidth: .infinity, alignment: .leading)
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(tokens.secondaryText)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("ui.close"))
                    .accessibilityIdentifier(closeAccessibilityIdentifier)
                }
            }
            if hasActions || technicalDetail != nil {
                // 只包按钮这一行：放不下（大字号、窄屏）时改成竖排，不截断按钮文字。
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        actionRow
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        actionRow
                    }
                }
                .padding(.leading, 32)
            }
            if showsDetail, let technicalDetail {
                TechnicalDetailPanel(detail: technicalDetail)
                    .padding(.leading, 32)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tokens.elevatedSurface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(borderColor(tokens), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .onChange(of: title) { _, _ in
            showsDetail = false
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        actions()
        if technicalDetail != nil {
            TechnicalDetailToggle(isExpanded: $showsDetail)
        }
    }

    private var iconStyle: InAppToast.Style {
        switch tone {
        case .neutral, .warning:
            return .info
        case .failure:
            return .failure
        case .progress:
            return .progress
        }
    }

    private func iconTint(_ tokens: ThemeTokens) -> Color? {
        tone == .warning ? tokens.warning : nil
    }

    private func borderColor(_ tokens: ThemeTokens) -> Color {
        switch tone {
        case .failure:
            // 与失败轻提示同一道描边。
            return Color.red.opacity(0.35)
        case .warning:
            return tokens.warning.opacity(0.42)
        case .neutral, .progress:
            return tokens.border
        }
    }
}

/// 会话页顶部的错误横幅：取代原来的红色「错误：…」胶囊。
///
/// 只展示翻译后的结论；原始错误收在「显示详情」里，可复制。链路类失败直接给出「重新连接」，
/// 进行中的自动重连改用中性样式和进度指示。版式与轻提示一致（`InlineNoticeCard`）。
struct ErrorPresentationBanner: View {
    let presentation: UserFacingError
    let isReconnecting: Bool
    let onReconnect: () -> Void
    let onDismiss: () -> Void

    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        InlineNoticeCard(
            tone: presentation.isInProgress ? .progress : .failure,
            title: presentation.message,
            technicalDetail: presentation.technicalDetail,
            hasActions: presentation.suggestsReconnect,
            onClose: onDismiss,
            closeAccessibilityIdentifier: "conversation.errorBanner.close"
        ) {
            if presentation.suggestsReconnect {
                Button(action: onReconnect) {
                    Label(L10n.text("ui.reconnect"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(tokens.primaryActionForeground)
                .controlSize(.small)
                .disabled(isReconnecting)
                .accessibilityIdentifier("conversation.errorBanner.reconnect")
            }
        }
        .accessibilityIdentifier("conversation.errorBanner")
        .onChange(of: presentation.message, initial: true) { _, message in
            AccessibilityNotification.Announcement(message).post()
        }
    }
}

private struct FeedbackStatusIcon: View {
    let style: InAppToast.Style
    let systemImage: String?
    let tokens: ThemeTokens
    /// 页面内卡片的警示色（额度）不在轻提示的样式里，由调用方直接给。
    var tintOverride: Color? = nil

    var body: some View {
        Group {
            if style == .progress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: systemImage ?? defaultSymbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tintOverride ?? tint)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }

    private var defaultSymbol: String {
        switch style {
        case .info:
            return "info.circle.fill"
        case .success:
            return "checkmark.circle.fill"
        case .failure:
            return "exclamationmark.triangle.fill"
        case .progress:
            return "arrow.triangle.2.circlepath"
        }
    }

    private var tint: Color {
        switch style {
        case .info, .progress:
            return tokens.accent
        case .success:
            return tokens.success
        case .failure:
            return .red
        }
    }
}

private struct TechnicalDetailToggle: View {
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Label(
                isExpanded ? L10n.text("ui.hide_details") : L10n.text("ui.show_details"),
                systemImage: isExpanded ? "chevron.up" : "chevron.down"
            )
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("feedback.details")
    }
}

/// 展开后的技术详情：等宽、可选中、可一键复制（附 App 版本，方便与支持人员对齐）。
private struct TechnicalDetailPanel: View {
    let detail: String

    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var didCopy = false

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                Text(detail)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(tokens.secondaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            .fixedSize(horizontal: false, vertical: true)
            Button {
                UIPasteboard.general.string = [
                    L10n.format("ui.app_version_value", SessionLogExportBuilder.currentAppVersion()),
                    detail
                ].joined(separator: "\n")
                didCopy = true
            } label: {
                Label(
                    didCopy ? L10n.text("ui.error_details_copied") : L10n.text("ui.copy_error_details"),
                    systemImage: didCopy ? "checkmark" : "doc.on.doc"
                )
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .font(themeStore.uiFont(.caption, weight: .medium))
            .accessibilityIdentifier("feedback.copyDetails")
        }
        .padding(10)
        .background(tokens.codeBlock.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

extension View {
    /// 把 `SessionStore.operationFeedback`（即所有 `setStatusMessage` 写入口）挂到顶部轻提示上。
    func operationFeedbackToasts() -> some View {
        modifier(OperationFeedbackToastHost())
    }
}

private struct OperationFeedbackToastHost: ViewModifier {
    @EnvironmentObject private var sessionStore: SessionStore

    func body(content: Content) -> some View {
        content.inAppToast(visibleToast) { id in
            sessionStore.dismissOperationFeedback(id: id.base as? UUID)
        }
    }

    private var visibleToast: InAppToast? {
        guard let feedback = sessionStore.operationFeedback else {
            return nil
        }
        // 同一句话已经由会话页的错误横幅展示时不再重复弹出（例如凭据失效同时写入两条通道）。
        if feedback.message == sessionStore.errorPresentation?.message {
            return nil
        }
        return InAppToast(feedback: feedback) { feedback in
            Task { await sessionStore.retryOperationFeedback(feedback) }
        }
    }
}

/// 表单里的就地失败说明（例如重命名弹窗）：一句结论，可展开技术详情。
struct OperationFailureFootnote: View {
    let feedback: OperationFeedback

    @EnvironmentObject private var themeStore: ThemeStore
    @State private var showsDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(feedback.message, systemImage: "exclamationmark.triangle.fill")
                .font(themeStore.uiFont(.footnote, weight: .medium))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("operationFailure.message")
            if let detail = feedback.technicalDetail {
                TechnicalDetailToggle(isExpanded: $showsDetail)
                if showsDetail {
                    TechnicalDetailPanel(detail: detail)
                }
            }
        }
        .padding(.top, 4)
    }
}

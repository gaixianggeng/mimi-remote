import SwiftUI

/// 上下文剩余比例的小饼图：外圈细线是整个窗口，内部扇形是剩余部分，随对话推进逐渐变小。
/// 不用弧形圆环，是因为「一段弧」会被读成加载转圈（加载指示器正是轨道弧）。
/// 只画图形不写数字，具体比例放在点按后的菜单和无障碍朗读里，避免工具栏再多一个文字控件。
struct ContextWindowRing: View {
    let usage: ContextWindowUsage
    let tint: Color
    var diameter: CGFloat = 17

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.55), lineWidth: 1.5)
            ContextWindowRemainingWedge(fraction: Double(usage.remainingPercent) / 100)
                .fill(tint)
                .padding(3)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

/// 从 12 点方向顺时针展开的扇形；满额时画整圆，空时不画。
struct ContextWindowRemainingWedge: Shape {
    var fraction: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let clamped = min(1, max(0, fraction))
        guard clamped > 0 else {
            return path
        }
        guard clamped < 1 else {
            path.addEllipse(in: rect)
            return path
        }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(
            center: center,
            radius: min(rect.width, rect.height) / 2,
            startAngle: .degrees(-90),
            endAngle: .degrees(-90 + 360 * clamped),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

extension ComposerView {
    var showsContextWindowRingInToolbar: Bool {
        ConversationLayout.composerShowsContextRing(tier: composerTier, availableWidth: availableWidth)
    }

    // 与紧凑工具栏的其他控件一样先在独立栈帧里擦除类型，避免真机收集泛型元数据时栈溢出。
    @inline(never)
    func compactContextWindowControlBox() -> AnyView {
        AnyView(contextWindowRingControl)
    }

    @ViewBuilder
    var contextWindowRingControl: some View {
        if showsContextWindowRingInToolbar,
           let session = sessionStore.selectedSession,
           let usage = sessionStore.contextWindowUsage(for: session) {
            let tokens = themeStore.tokens(for: colorScheme)
            let percentText = Self.contextWindowPercentText(usage)
            Menu {
                contextWindowMenuItems(session: session, usage: usage)
            } label: {
                ContextWindowRing(
                    usage: usage,
                    tint: usage.isLow ? tokens.warning : tokens.conversationSecondaryText
                )
                .frame(width: usesNarrowComposerLayout ? 32 : 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
            .accessibilityLabel(L10n.format("ui.context_window_remaining_value", percentText))
            .accessibilityHint(L10n.text("ui.context_window_hint"))
            .accessibilityIdentifier("composer.contextWindow")
        }
    }

    /// 圆环菜单与「选项」菜单共用：剩余比例、已用 / 窗口，以及 Codex 会话的压缩入口。
    @ViewBuilder
    func contextWindowMenuItems(session: AgentSession, usage: ContextWindowUsage) -> some View {
        Section(L10n.format("ui.context_window_remaining_value", Self.contextWindowPercentText(usage))) {
            Text(L10n.format(
                "ui.context_window_used_value",
                ConversationLiveStatus.compactTokenCount(usage.usedTokens),
                ConversationLiveStatus.compactTokenCount(usage.contextWindow)
            ))
            if sessionStore.supportsCodexThreadManagement(session) {
                Button {
                    Task { await sessionStore.compactContextFromContextWindowControl(session) }
                } label: {
                    Label(L10n.text("ui.compression_context"), systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .disabled(session.isRunning)
            }
        }
    }

    /// 工具栏放不下圆环时（窄宽度），把同样的信息和压缩入口放进「选项」菜单。
    @ViewBuilder
    var contextWindowOptionsMenuFallback: some View {
        if !showsContextWindowRingInToolbar,
           let session = sessionStore.selectedSession,
           let usage = sessionStore.contextWindowUsage(for: session) {
            contextWindowMenuItems(session: session, usage: usage)
        }
    }

    /// 剩余上下文不足时在输入框上方提示一次；关闭后直到压缩回阈值以上才会再次出现。
    @ViewBuilder
    var contextWindowNotice: some View {
        if sessionStore.showsSelectedContextWindowNotice,
           let session = sessionStore.selectedSession,
           let usage = sessionStore.contextWindowUsage(for: session) {
            let tokens = themeStore.tokens(for: colorScheme)
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .accessibilityHidden(true)
                Text(L10n.format("ui.context_window_low_notice_value", Self.contextWindowPercentText(usage)))
                    .lineLimit(2)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                if sessionStore.supportsCodexThreadManagement(session) {
                    Button(L10n.text("ui.compression_context")) {
                        Task { await sessionStore.compactContextFromContextWindowControl(session) }
                    }
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(session.isRunning)
                    .accessibilityIdentifier("composer.contextWindow.compact")
                }
                Button {
                    sessionStore.dismissContextWindowNotice(sessionID: session.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(themeStore.uiFont(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("ui.close"))
                .accessibilityIdentifier("composer.contextWindow.dismiss")
            }
            .font(themeStore.uiFont(.caption))
            .foregroundStyle(tokens.warning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }

    static func contextWindowPercentText(_ usage: ContextWindowUsage) -> String {
        "\(usage.remainingPercent)%"
    }
}

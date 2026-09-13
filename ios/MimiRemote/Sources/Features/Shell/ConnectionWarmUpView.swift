import SwiftUI

/// 首次连接一台电脑时的过渡界面。
///
/// 冷启动和切换电脑都要先建隧道、再等 agentd 网关的上游就绪，这个窗口内的失败是过程
/// 而不是结论。用内容形状的骨架而不是错误态或转圈占位：形状本身告诉用户接下来会出现
/// 什么，等真实数据到位时替换的是同一块版面，不会整屏跳变。
struct ConnectionWarmUpView: View {
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 骨架行数。会话页给完整列表高度，工作区页只需要提示接下来是一份列表。
    var rowCount = 3
    /// 说明文案。默认解释“通道正在建立”，调用方可替换成本页面更贴切的说明。
    var message: String?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 20) {
            header(tokens: tokens)
            skeleton(tokens: tokens)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(resolvedMessage)
        .accessibilityIdentifier("connection.warmUp")
    }

    /// 连接目标写在标题里。用户同时配对多台电脑时，"正在连接" 本身并不足以说明发生了什么。
    private var title: String {
        guard let displayName = appStore.activeConnectionProfile?.displayName,
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return L10n.text("ui.connecting_to_your_mac")
        }
        return L10n.format("ui.connecting_to_value", displayName)
    }

    private var resolvedMessage: String {
        message ?? L10n.text("ui.a_secure_channel_is_being_established_content_appears")
    }

    private func header(tokens: ThemeTokens) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(tokens.secondaryText)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(themeStore.uiFont(.subheadline, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Text(resolvedMessage)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    private func skeleton(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(0..<max(1, rowCount), id: \.self) { index in
                ConnectionWarmUpSkeletonRow(
                    tokens: tokens,
                    titleTrailingInset: Self.titleTrailingInsets[index % Self.titleTrailingInsets.count],
                    subtitleTrailingInset: Self.subtitleTrailingInsets[index % Self.subtitleTrailingInsets.count]
                )
            }
        }
        .connectionWarmUpShimmer(tokens: tokens, isAnimating: !reduceMotion)
    }

    /// 参差的行宽让骨架读起来像一份真实列表，而不是一组等宽色块。
    private static let titleTrailingInsets: [CGFloat] = [72, 132, 40, 104]
    private static let subtitleTrailingInsets: [CGFloat] = [168, 118, 196, 146]
}

/// 单行骨架：左侧头像位，右侧标题与摘要两行。与会话行同构，替换成真实内容时版面不跳。
private struct ConnectionWarmUpSkeletonRow: View {
    let tokens: ThemeTokens
    let titleTrailingInset: CGFloat
    let subtitleTrailingInset: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tokens.elevatedSurface)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 9) {
                bar(height: 12, trailingInset: titleTrailingInset)
                bar(height: 9, trailingInset: subtitleTrailingInset)
            }
        }
    }

    private func bar(height: CGFloat, trailingInset: CGFloat) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                .fill(tokens.elevatedSurface)
                .frame(height: height)
            // 用固定宽度的透明尾段制造参差；容器变窄时让色块自己收缩，不会溢出。
            Color.clear
                .frame(width: trailingInset, height: height)
        }
    }
}

/// 骨架扫光。只在骨架自身的形状里移动，不在整块矩形上刷一道高光，
/// 否则它会读成一个独立的发光层，而不是"这些内容正在填充"。
private struct ConnectionWarmUpShimmer: ViewModifier {
    let tokens: ThemeTokens
    let isAnimating: Bool

    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                if isAnimating {
                    GeometryReader { proxy in
                        let sweepWidth = max(proxy.size.width * 0.42, 88)
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: tokens.primaryText.opacity(0.12), location: 0.5),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: sweepWidth)
                        .offset(x: phase * (proxy.size.width + sweepWidth) - sweepWidth)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            .task(id: isAnimating) {
                guard isAnimating else {
                    phase = 0
                    return
                }
                // 线性匀速：扫光是背景节奏，不该有加速感去抢用户注意。
                phase = 0
                withAnimation(.linear(duration: 1.45).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

extension View {
    /// Reduce Motion 下只保留静态骨架：形状仍然预告版面，但不做横向位移。
    func connectionWarmUpShimmer(tokens: ThemeTokens, isAnimating: Bool) -> some View {
        modifier(ConnectionWarmUpShimmer(tokens: tokens, isAnimating: isAnimating))
    }
}

import AppKit
import Foundation
import SwiftUI

struct PairingView: View {
    let store: HostStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var didCopyPairingLink = false
    @State private var isRefreshing = false
    @State private var selectedNetwork: PairingNetwork = .tailscale
    @State private var suppressNextNetworkChange = false
    @State private var copyFeedbackTask: Task<Void, Never>?
    @State private var contentOverflows = false

    /// 窗口可以被拉宽，但这一页只有一件事：扫码。内容始终是一列固定宽度，不跟着窗口摊开。
    static let columnWidth: CGFloat = 340

    var body: some View {
        Group {
            if let pairing = store.pairing {
                pairingContent(pairing)
            } else if let error = store.lastError {
                PairingUnavailableState(
                    title: "暂时无法生成二维码",
                    description: error,
                    isRetrying: isRefreshing,
                    retry: { refreshPairing() }
                )
            } else {
                PairingLoadingState()
            }
        }
        .frame(minWidth: 420, minHeight: 560)
        // macOS 26 的玻璃材质留给窗口 chrome 和操作控件，二维码内容层保持安静、稳定。
        .containerBackground(for: .window) {
            PairingWindowBackdrop()
        }
        .task {
            if store.pairing == nil {
                await store.refreshPairing()
            }
            if selectedNetwork != store.pairingNetwork {
                suppressNextNetworkChange = true
                selectedNetwork = store.pairingNetwork
            }
        }
        .onChange(of: selectedNetwork) { _, network in
            if suppressNextNetworkChange {
                suppressNextNetworkChange = false
                return
            }
            refreshPairing(network: network)
        }
        .onDisappear {
            copyFeedbackTask?.cancel()
        }
    }

    private func pairingContent(_ pairing: PairingInfo) -> some View {
        let visibleWarnings = pairing.warnings + [store.lastError].compactMap { $0 }
        return ScrollView {
            VStack(spacing: 0) {
                PairingIntroduction()
                    .padding(.bottom, 20)

                PairingNetworkPicker(
                    selection: $selectedNetwork,
                    isRefreshing: isRefreshing
                )
                .padding(.bottom, 20)

                PairingCodeCard(value: pairing.pairURL, isRefreshing: isRefreshing)
                    .padding(.bottom, 16)

                Text(pairing.endpoint)
                    .font(.system(.callout, design: .monospaced, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                if !pairing.expiresAt.isEmpty {
                    PairingExpiryStatus(rawValue: pairing.expiresAt)
                        .padding(.top, 10)
                }

                if !visibleWarnings.isEmpty {
                    PairingWarningList(warnings: visibleWarnings)
                        .padding(.top, 16)
                }
            }
            .frame(width: Self.columnWidth)
            .frame(maxWidth: .infinity)
            .padding(.top, 26)
            .padding(.bottom, 18)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            let available = geometry.containerSize.height
                - geometry.contentInsets.top
                - geometry.contentInsets.bottom
            return geometry.contentSize.height > available + 1
        } action: { _, overflows in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                contentOverflows = overflows
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PairingActionBar(
                didCopy: didCopyPairingLink,
                isRefreshing: isRefreshing,
                copy: { copyPairingLink(pairing.pairURL) },
                refresh: { refreshPairing() }
            )
            .frame(width: Self.columnWidth)
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            .padding(.bottom, 18)
            // 内容真的会滚到操作栏底下时才加边缘虚化，页面放得下时不留一条多余的横带。
            .background(alignment: .top) {
                if contentOverflows {
                    PairingScrollEdge()
                }
            }
        }
    }

    private func copyPairingLink(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)

        copyFeedbackTask?.cancel()
        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 1)) {
            didCopyPairingLink = true
        }
        copyFeedbackTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 1)) {
                didCopyPairingLink = false
            }
        }
    }

    private func refreshPairing(network: PairingNetwork? = nil) {
        guard !isRefreshing else { return }
        let targetNetwork = network ?? selectedNetwork
        isRefreshing = true
        Task {
            await store.refreshPairing(network: targetNetwork)
            if store.pairingNetwork != targetNetwork {
                suppressNextNetworkChange = true
                selectedNetwork = store.pairingNetwork
            }
            isRefreshing = false
        }
    }
}

private struct PairingIntroduction: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(Circle().fill(Color.accentColor.gradient))
                .shadow(color: Color.accentColor.opacity(0.3), radius: 10, y: 4)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("扫描二维码")
                    .font(.system(size: 26, weight: .bold))
                    // 大字号里字距要收紧，否则标题看起来是散的。
                    .tracking(-0.5)

                Text("在 iPhone 或 iPad 上打开 Mimi Remote，然后扫描下方二维码。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 300)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PairingNetworkPicker: View {
    @Binding var selection: PairingNetwork
    let isRefreshing: Bool

    var body: some View {
        VStack(spacing: 8) {
            Picker("配对网络", selection: $selection) {
                Text("Tailscale")
                    .tag(PairingNetwork.tailscale)
                Text("Tailcat 实验")
                    .tag(PairingNetwork.tailcat)
                Text("局域网")
                    .tag(PairingNetwork.localNetwork)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .frame(maxWidth: 320)
            .disabled(isRefreshing)
            .accessibilityHint("选择用于生成配对二维码的连接网络")

            Label(hint, systemImage: hintSymbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                // 说明文案长度不一，留一行固定高度，切换网络时二维码不会上下跳。
                .frame(minHeight: 18)
                .contentTransition(.opacity)
                .id(selection)
        }
        .accessibilityElement(children: .contain)
    }

    private var hint: String {
        switch selection {
        case .automatic:
            "自动选择可用网络"
        case .tailscale:
            "默认推荐 · 支持跨网络连接"
        case .localNetwork:
            "设备需在同一局域网 · 首次启用会重启服务"
        case .tailcat:
            "邀请实验 · 不依赖已安装的 Tailscale 客户端"
        }
    }

    private var hintSymbol: String {
        switch selection {
        case .automatic: "arrow.triangle.branch"
        case .tailscale: "network"
        case .localNetwork: "wifi"
        case .tailcat: "point.3.connected.trianglepath.dotted"
        }
    }
}

private struct PairingCodeCard: View {
    let value: String
    let isRefreshing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 二维码底板固定为白色：扫码对比度不跟随外观模式，深色模式下也要能扫。
        QRCodeView(value: value, size: 240)
            .padding(16)
            .background(.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.black.opacity(0.06), lineWidth: 1)
            }
            .overlay {
                if isRefreshing {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.white.opacity(0.7))
                        .overlay {
                            ProgressView()
                                .controlSize(.large)
                        }
                }
            }
            .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isRefreshing)
            .accessibilityValue(isRefreshing ? "正在生成新的二维码" : "可扫描")
    }
}

struct PairingExpiryStatus: View {
    let rawValue: String

    var body: some View {
        if let expiryDate = Self.expiryDate(from: rawValue) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                statusLabel(at: context.date, expiryDate: expiryDate)
            }
        } else {
            Label(Self.fallbackText(for: rawValue), systemImage: "lock.shield")
                .pairingStatusCapsule(foregroundColor: .secondary)
                .accessibilityLabel("配对二维码有效期")
                .accessibilityValue(Self.fallbackText(for: rawValue))
        }
    }

    private func statusLabel(at now: Date, expiryDate: Date) -> some View {
        let expired = expiryDate <= now
        let text = statusText(at: now, expiryDate: expiryDate)
        return Label(
            text,
            systemImage: expired ? "exclamationmark.lock" : "clock.badge.checkmark"
        )
        .pairingStatusCapsule(foregroundColor: expired ? .orange : .secondary)
        .accessibilityLabel("配对二维码有效期")
        .accessibilityValue(text)
    }

    static func expiryDate(from rawValue: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: rawValue) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: rawValue)
    }

    static func fallbackText(for rawValue: String) -> String {
        if rawValue.contains("后") || rawValue.contains("有效") || rawValue.contains("失效") {
            return rawValue
        }
        return "有效至 \(rawValue)"
    }

    func statusText(at now: Date, expiryDate: Date) -> String {
        let remaining = expiryDate.timeIntervalSince(now)
        if remaining <= 0 {
            return "二维码已失效"
        }
        if remaining < 60 {
            return "\(max(1, Int(ceil(remaining)))) 秒后失效"
        }
        if remaining < 60 * 60 {
            return "\(Int(ceil(remaining / 60))) 分钟后失效"
        }
        if Calendar.current.isDate(expiryDate, inSameDayAs: now) {
            return "有效至 \(expiryDate.formatted(date: .omitted, time: .shortened))"
        }
        return "有效至 \(expiryDate.formatted(date: .abbreviated, time: .shortened))"
    }
}

private extension View {
    func pairingStatusCapsule(foregroundColor: Color) -> some View {
        font(.caption.weight(.medium))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.055), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }
}

private struct PairingWarningList: View {
    let warnings: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(warnings, id: \.self) { warning in
                Label {
                    Text(warning)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.16), lineWidth: 1)
        }
    }
}

/// 内容滚到操作栏下面时，用一层渐隐材质把文字收进 chrome，而不是压出一条硬分割线。
private struct PairingScrollEdge: View {
    var body: some View {
        Rectangle()
            .fill(.thinMaterial)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.5), location: 0.35),
                        .init(color: .black, location: 0.66),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

private struct PairingActionBar: View {
    let didCopy: Bool
    let isRefreshing: Bool
    let copy: () -> Void
    let refresh: () -> Void

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 10) {
                    actionButtons
                }
            } else {
                actionButtons
            }
        }
        .controlSize(.large)
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button(action: copy) {
                Label(
                    didCopy ? "已复制" : "复制配对链接",
                    systemImage: didCopy ? "checkmark" : "doc.on.doc"
                )
                .frame(maxWidth: .infinity, minHeight: 22)
                .contentShape(Rectangle())
            }
            .modifier(PairingActionButtonStyleModifier(isProminent: false))
            .help("复制这条十分钟有效的配对链接")
            .accessibilityLabel(didCopy ? "配对链接已复制" : "复制配对链接")
            .accessibilityHint("将当前十分钟有效的配对链接复制到剪贴板")

            Button(action: refresh) {
                HStack(spacing: 6) {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(isRefreshing ? "正在刷新" : "刷新二维码")
                }
                .frame(maxWidth: .infinity, minHeight: 22)
                .contentShape(Rectangle())
            }
            .modifier(PairingActionButtonStyleModifier(isProminent: true))
            .disabled(isRefreshing)
            .keyboardShortcut("r", modifiers: .command)
            .help("生成一张新的十分钟配对二维码（⌘R）")
            .accessibilityLabel(isRefreshing ? "正在刷新二维码" : "刷新二维码")
            .accessibilityHint("生成一张新的十分钟配对二维码")
            .accessibilityValue(isRefreshing ? "进行中" : "就绪")
        }
    }
}

private struct PairingLoadingState: View {
    var body: some View {
        PairingPlaceholder(
            symbol: "qrcode.viewfinder",
            symbolColor: .accentColor,
            title: "正在生成二维码",
            message: "配对码仅在短时间内有效。"
        ) {
            ProgressView()
                .controlSize(.small)
        }
    }
}

private struct PairingUnavailableState: View {
    let title: String
    let description: String
    let isRetrying: Bool
    let retry: () -> Void

    var body: some View {
        PairingPlaceholder(
            symbol: "qrcode",
            symbolColor: .secondary,
            title: title,
            message: description,
            isMessageSelectable: true
        ) {
            Button(action: retry) {
                HStack(spacing: 6) {
                    if isRetrying {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(isRetrying ? "正在重新生成" : "重新生成")
                }
                .frame(minWidth: 132, minHeight: 22)
                .contentShape(Rectangle())
            }
            .modifier(PairingActionButtonStyleModifier(isProminent: true))
            .controlSize(.large)
            .disabled(isRetrying)
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityLabel(isRetrying ? "正在重新生成二维码" : "重新生成二维码")
            .accessibilityHint("重试生成一张新的十分钟配对二维码")
            .accessibilityValue(isRetrying ? "进行中" : "可重试")
        }
    }
}

/// 加载态和失败态共用同一套排版，二维码没出现时页面重心也不会跳。
private struct PairingPlaceholder<Action: View>: View {
    let symbol: String
    let symbolColor: Color
    let title: String
    let message: String
    var isMessageSelectable = false
    @ViewBuilder let action: () -> Action

    // 失败态的报错要能被选中复制，加载态的固定文案不需要。
    @ViewBuilder private var messageText: some View {
        let base = Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        if isMessageSelectable {
            base.textSelection(.enabled)
        } else {
            base
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 38, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(symbolColor)

            VStack(spacing: 7) {
                Text(title)
                    .font(.title3.weight(.semibold))

                messageText
            }

            action()
                .padding(.top, 2)
        }
        .frame(width: PairingView.columnWidth)
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PairingActionButtonStyleModifier: ViewModifier {
    let isProminent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        // 仅让支持 Liquid Glass 的系统使用玻璃按钮，旧系统保留相同的原生交互语义。
        if #available(macOS 26.0, *) {
            if isProminent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else if isProminent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

private struct PairingWindowBackdrop: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)

            // 只留一处品牌光晕落在标题后面，避免多个彩色渐变互相染成脏色。
            RadialGradient(
                colors: [Color.accentColor.opacity(0.16), .clear],
                center: UnitPoint(x: 0.5, y: 0),
                startRadius: 0,
                endRadius: 420
            )

            LinearGradient(
                colors: [.clear, Color.black.opacity(0.05)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
    }
}

#if DEBUG
    #Preview {
        PairingView(store: .preview(.ready))
            .frame(width: 520, height: 720)
    }
#endif

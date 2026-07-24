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

    var body: some View {
        Group {
            if let pairing = store.pairing {
                pairingContent(pairing)
            } else if let error = store.lastError {
                PairingUnavailableState(
                    title: "暂时无法生成二维码",
                    description: error,
                    retry: { refreshPairing() }
                )
            } else {
                PairingLoadingState()
            }
        }
        .frame(minWidth: 480, minHeight: 660)
        // macOS 27 的玻璃材质留给窗口 chrome 和操作控件，二维码内容层保持安静、稳定。
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
                    .padding(.bottom, 18)

                PairingNetworkPicker(
                    selection: $selectedNetwork,
                    isRefreshing: isRefreshing
                )
                .padding(.bottom, 20)

                QRCodeView(value: pairing.pairURL, size: 276)
                    .padding(20)
                    .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(.black.opacity(0.07), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.08), radius: 20, y: 8)
                    .padding(.bottom, 18)

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
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PairingActionBar(
                didCopy: didCopyPairingLink,
                isRefreshing: isRefreshing,
                copy: { copyPairingLink(pairing.pairURL) },
                refresh: { refreshPairing() }
            )
            .padding(.horizontal, 28)
            .padding(.top, 10)
            .padding(.bottom, 20)
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
        VStack(spacing: 12) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 25, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 54, height: 54)
                .background(Color.accentColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(spacing: 7) {
                Text("扫描二维码")
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.55)

                Text("在 iPhone 或 iPad 上打开 Mimi Remote，\n然后扫描下方二维码。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
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
                Text("局域网")
                    .tag(PairingNetwork.localNetwork)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 300)
            .disabled(isRefreshing)

            Label(hint, systemImage: hintSymbol)
                .font(.caption)
                .foregroundStyle(.secondary)
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
        }
    }

    private var hintSymbol: String {
        switch selection {
        case .automatic: "arrow.triangle.branch"
        case .tailscale: "network"
        case .localNetwork: "wifi"
        }
    }
}

private struct PairingExpiryStatus: View {
    let rawValue: String

    var body: some View {
        if let expiryDate {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                statusLabel(at: context.date, expiryDate: expiryDate)
            }
        } else {
            Label(fallbackText, systemImage: "lock.shield")
                .pairingStatusCapsule(foregroundColor: .secondary)
        }
    }

    private func statusLabel(at now: Date, expiryDate: Date) -> some View {
        let expired = expiryDate <= now
        return Label(
            statusText(at: now, expiryDate: expiryDate),
            systemImage: expired ? "exclamationmark.lock" : "clock.badge.checkmark"
        )
        .pairingStatusCapsule(foregroundColor: expired ? .orange : .secondary)
    }

    private var expiryDate: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: rawValue) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: rawValue)
    }

    private var fallbackText: String {
        if rawValue.contains("后") || rawValue.contains("有效") || rawValue.contains("失效") {
            return "\(rawValue) · 一次性连接码"
        }
        return "有效至 \(rawValue) · 一次性连接码"
    }

    private func statusText(at now: Date, expiryDate: Date) -> String {
        let remaining = expiryDate.timeIntervalSince(now)
        if remaining <= 0 {
            return "二维码已失效 · 一次性连接码"
        }
        if remaining < 60 {
            return "\(max(1, Int(ceil(remaining)))) 秒后失效 · 一次性连接码"
        }
        if remaining < 60 * 60 {
            return "\(Int(ceil(remaining / 60))) 分钟后失效 · 一次性连接码"
        }
        if Calendar.current.isDate(expiryDate, inSameDayAs: now) {
            return "有效至 \(expiryDate.formatted(date: .omitted, time: .shortened)) · 一次性连接码"
        }
        return "有效至 \(expiryDate.formatted(date: .abbreviated, time: .shortened)) · 一次性连接码"
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
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: 356, alignment: .leading)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.18), lineWidth: 1)
        }
    }
}

private struct PairingActionBar: View {
    let didCopy: Bool
    let isRefreshing: Bool
    let copy: () -> Void
    let refresh: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button(action: copy) {
                    Label(
                        didCopy ? "已复制" : "复制配对链接",
                        systemImage: didCopy ? "checkmark" : "doc.on.doc"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .accessibilityLabel(didCopy ? "配对链接已复制" : "复制配对链接")

                Button(action: refresh) {
                    HStack(spacing: 7) {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(isRefreshing ? "正在刷新" : "刷新二维码")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .disabled(isRefreshing)
            }
        }
        .controlSize(.large)
    }
}

private struct PairingLoadingState: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 42, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("正在生成二维码")
                    .font(.title2.weight(.semibold))
                Text("配对码仅在短时间内有效。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ProgressView()
                .controlSize(.small)
        }
        .padding(40)
        .accessibilityElement(children: .combine)
    }
}

private struct PairingUnavailableState: View {
    let title: String
    let description: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "qrcode")
                .font(.system(size: 42, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 340)
            }

            Button("重新生成", systemImage: "arrow.clockwise", action: retry)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
        }
        .padding(40)
    }
}

private struct PairingWindowBackdrop: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)

            RadialGradient(
                colors: [Color.accentColor.opacity(0.16), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 380
            )

            RadialGradient(
                colors: [Color.purple.opacity(0.10), .clear],
                center: .bottomTrailing,
                startRadius: 10,
                endRadius: 360
            )

            Color.white.opacity(0.04)
        }
    }
}

#if DEBUG
    #Preview {
        PairingView(store: .preview(.ready))
            .frame(width: 520, height: 680)
    }
#endif

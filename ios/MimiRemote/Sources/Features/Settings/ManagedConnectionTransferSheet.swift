import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 决定要不要把邀请码显示出来（#989）。这个码拿到就能开通，所以先确认是机主本人。
enum ManagedConnectionTransferGate {
    enum Outcome: Equatable {
        case reveal(String)
        case cancelled
        case failed
        /// 钥匙串里没有这台设备开通时用的码（例如重装后），验证机主也拿不出来，不能说成验证没通过。
        case codeUnavailable
    }

    static func requestCode(
        _ code: String?,
        authenticator: any DeviceOwnerAuthenticating,
        reason: String
    ) async -> Outcome {
        guard let code else { return .codeUnavailable }
        switch await authenticator.authenticate(reason: reason) {
        case .authenticated:
            return .reveal(code)
        case .notConfigured:
            // 没设锁屏密码的设备，系统给不出验证手段；拦住只会让机主本人也转不了。
            return .reveal(code)
        case .cancelled:
            return .cancelled
        case .failed:
            return .failed
        }
    }
}

struct ManagedConnectionTransferCode: Identifiable, Equatable {
    let code: String
    var id: String { code }
}

/// 在已开通的设备上出示邀请码，用户的另一台设备扫码或粘贴后即可开通（#989）。
struct ManagedConnectionTransferSheet: View {
    /// 足够拿起另一台设备粘贴，又不让能开通服务的码长期留在剪贴板。
    static let clipboardLifetime: TimeInterval = 5 * 60

    let code: String
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var qrImage: UIImage?
    @State private var didCopy = false
    @State private var copyFeedbackTask: Task<Void, Never>?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        NavigationStack {
            Form {
                // 应用切换器的截图在失去活跃时生成，不能等关闭动画：这一帧起就不画码。
                if scenePhase == .active {
                    Section {
                        codeCard(tokens: tokens)
                    } header: {
                        SettingsGroupHeader(showsDivider: false)
                    }
                    .settingsGroupRowStyle()

                    Section {
                        copyButton(tokens: tokens)
                    } header: {
                        SettingsGroupHeader()
                    } footer: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.text("ui.managed_transfer_copy_hint"))
                            Text(L10n.text("ui.managed_transfer_private_note"))
                        }
                        .settingsSectionFooterStyle()
                    }
                    .settingsGroupRowStyle()
                }
            }
            .themedSettingsForm(tokens: tokens)
            .settingsDetailPage(tokens: tokens)
            .navigationTitle(L10n.text("ui.managed_transfer_add_device"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.text("ui.done"), action: onClose)
                        .accessibilityIdentifier("settings.managedSubscription.transfer.done")
                }
            }
        }
        .task(id: code) {
            qrImage = ManagedRedemptionLink.url(forCode: code)
                .flatMap { CommunityQRCode.image(for: $0.absoluteString) }
        }
        // 离开前台就收起：回来要重新验证，码也不留在内存里。
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { onClose() }
        }
        .onDisappear {
            copyFeedbackTask?.cancel()
        }
        .accessibilityIdentifier("settings.managedSubscription.transfer")
    }

    private func codeCard(tokens: ThemeTokens) -> some View {
        VStack(spacing: 12) {
            Group {
                if let qrImage {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                } else {
                    Color.white
                }
            }
            .frame(width: 220, height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement()
            .accessibilityLabel(L10n.text("ui.managed_transfer_qr_label"))
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier("settings.managedSubscription.transfer.qrCode")

            Text(code)
                .font(.system(.body, design: .monospaced).weight(.medium))
                .foregroundStyle(tokens.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityIdentifier("settings.managedSubscription.transfer.code")

            Text(L10n.text("ui.managed_transfer_instruction"))
                .settingsCaptionStyle()
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func copyButton(tokens: ThemeTokens) -> some View {
        Button(action: copyCode) {
            SettingsValueLabel(
                title: L10n.text(didCopy ? "ui.managed_transfer_copied" : "ui.managed_transfer_copy_code"),
                systemImage: didCopy ? "checkmark" : "doc.on.doc",
                titleTint: tokens.accent
            )
        }
        .buttonStyle(.plain)
        .settingsStandardListRow()
        .accessibilityIdentifier("settings.managedSubscription.transfer.copy")
    }

    private func copyCode() {
        // 不设置 localOnly，才能通过系统通用剪贴板交给用户自己的另一台设备。
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: code]],
            options: [.expirationDate: Date().addingTimeInterval(Self.clipboardLifetime)]
        )
        didCopy = true
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }
}

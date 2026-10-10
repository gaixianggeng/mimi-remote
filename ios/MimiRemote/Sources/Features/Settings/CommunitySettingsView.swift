import CoreImage.CIFilterBuiltins
import Photos
import SwiftUI
import UIKit

/// 「加入用户群」用的开发者微信小号（#643）。
///
/// 个人微信二维码长期有效，所以直接写在包里，换号随版本更新，不走远端配置。
/// 二维码只存解出来的链接，由 App 重新生成，包里不放图片。
/// 链接为空时整个入口不出现，不把未配置的页面给用户看。
struct CommunityContact: Equatable {
    /// 微信「我的二维码」解出来的链接。
    let qrCodePayload: String
    /// 可搜索的微信号；为空时不显示「复制微信号」。
    let weChatID: String?

    static let bundled = CommunityContact.make(
        qrCodePayload: "https://u.wechat.com/EOXblOqhEHI1mskgGw5ehPo?s=2",
        weChatID: nil
    )

    static func make(qrCodePayload: String, weChatID: String?) -> CommunityContact? {
        let payload = qrCodePayload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return nil }
        let id = weChatID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CommunityContact(
            qrCodePayload: payload,
            weChatID: id?.isEmpty == false ? id : nil
        )
    }
}

enum CommunityQRCode {
    /// 二维码四周按规范留 4 个模块宽的白边。深色模式下卡片是深色，
    /// 白边必须画进图片本身，保存到相册的图也才能直接被扫。
    static let quietZoneModules: CGFloat = 4

    static func image(for payload: String, pixelsPerModule: CGFloat = 12) -> UIImage? {
        guard !payload.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: pixelsPerModule, y: pixelsPerModule))
        guard let code = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }

        let margin = pixelsPerModule * quietZoneModules
        let codeRect = CGRect(x: margin, y: margin, width: scaled.extent.width, height: scaled.extent.height)
        let size = CGSize(width: codeRect.width + margin * 2, height: codeRect.height + margin * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.interpolationQuality = .none
            UIImage(cgImage: code).draw(in: codeRect)
        }
    }
}

enum CommunityQRCodeSaveOutcome: Equatable {
    case saved
    case denied
    case failed
}

enum CommunityQRCodeSaver {
    /// 只申请「添加照片」权限，用户点了保存才问，不读取相册。
    static func save(_ image: UIImage) async -> CommunityQRCodeSaveOutcome {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            return .denied
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            return .saved
        } catch {
            return .failed
        }
    }
}

struct CommunitySettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    let contact: CommunityContact

    @State private var qrImage: UIImage?
    @State private var isSaving = false
    @State private var saveOutcome: CommunityQRCodeSaveOutcome?
    @State private var didCopyWeChatID = false
    @State private var feedbackResetTask: Task<Void, Never>?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            Section {
                qrCard(tokens: tokens)
            } header: {
                SettingsGroupHeader(showsDivider: false)
            }
            .settingsGroupRowStyle()

            Section {
                Button(action: saveQRCode) {
                    SettingsValueLabel(
                        title: saveOutcome == .saved
                            ? L10n.text("ui.community_qr_code_saved")
                            : L10n.text("ui.community_save_qr_code"),
                        systemImage: saveOutcome == .saved ? "checkmark" : "square.and.arrow.down",
                        titleTint: tokens.accent
                    )
                }
                .settingsStandardListRow()
                .disabled(qrImage == nil || isSaving)
                .accessibilityIdentifier("settings.community.saveQRCode")

                if let weChatID = contact.weChatID {
                    Button {
                        copyWeChatID(weChatID)
                    } label: {
                        SettingsValueLabel(
                            title: didCopyWeChatID
                                ? L10n.text("ui.community_wechat_id_copied")
                                : L10n.text("ui.community_copy_wechat_id"),
                            value: weChatID,
                            systemImage: didCopyWeChatID ? "checkmark" : "doc.on.doc",
                            titleTint: tokens.accent
                        )
                    }
                    .settingsStandardListRow()
                    .accessibilityIdentifier("settings.community.copyWeChatID")
                }
            } header: {
                SettingsGroupHeader()
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if let saveFailureMessage {
                        Text(saveFailureMessage)
                            .foregroundStyle(tokens.warning)
                            .accessibilityIdentifier("settings.community.saveFailure")
                    }
                    Text(scanHelp)
                    if contact.weChatID != nil {
                        Text(L10n.text("ui.community_search_help"))
                    }
                }
                .settingsSectionFooterStyle()
            }
            .settingsGroupRowStyle()
        }
        .themedSettingsForm(tokens: tokens)
        .settingsDetailPage()
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(L10n.text("ui.join_user_group"))
        .task(id: contact.qrCodePayload) {
            qrImage = CommunityQRCode.image(for: contact.qrCodePayload)
        }
        .onDisappear {
            feedbackResetTask?.cancel()
        }
    }

    private func qrCard(tokens: ThemeTokens) -> some View {
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
            .accessibilityLabel(L10n.text("ui.community_qr_accessibility_label"))
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier("settings.community.qrCode")

            Text(L10n.text("ui.community_group_name"))
                .settingsTitleFont(weight: .medium)
                .foregroundStyle(tokens.primaryText)

            Text(L10n.text("ui.community_add_instruction"))
                .settingsCaptionStyle()
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    /// 只给当前设备能用的那种扫法：iPhone 扫不了自己屏幕上的码，iPad 和 Mac 用手机扫。
    private var scanHelp: String {
        UIDevice.current.userInterfaceIdiom == .phone
            ? L10n.text("ui.community_scan_help_phone")
            : L10n.text("ui.community_scan_help_pad")
    }

    private var saveFailureMessage: String? {
        switch saveOutcome {
        case .denied:
            return L10n.text("ui.community_photos_access_denied")
        case .failed:
            return L10n.text("ui.community_save_failed")
        case .saved, nil:
            return nil
        }
    }

    private func saveQRCode() {
        guard let qrImage, !isSaving else { return }
        isSaving = true
        saveOutcome = nil
        Task {
            let outcome = await CommunityQRCodeSaver.save(qrImage)
            isSaving = false
            saveOutcome = outcome
            if outcome == .saved {
                scheduleFeedbackReset()
            }
        }
    }

    private func copyWeChatID(_ weChatID: String) {
        UIPasteboard.general.string = weChatID
        didCopyWeChatID = true
        scheduleFeedbackReset()
    }

    /// 「已保存」「已复制」只停留片刻；失败提示一直留到下次尝试，不自动消失。
    private func scheduleFeedbackReset() {
        feedbackResetTask?.cancel()
        feedbackResetTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            didCopyWeChatID = false
            if saveOutcome == .saved {
                saveOutcome = nil
            }
        }
    }
}

import SnapshotTesting
import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

/// #508：失败反馈的视觉基线。覆盖会话页错误横幅（宽屏 / iPhone）、顶部轻提示（含详情展开）
/// 与重命名弹窗里的就地失败说明；主界面文案里不应出现 HTTP / WebSocket 等原文。
/// #738：会话页的缩略历史、额度卡片与轻提示同一套版式。
@MainActor
final class OperationFeedbackSnapshotTests: SimplifiedChineseSnapshotTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "失败反馈快照只在固定 M5 iPad 宿主录制。"
        )
    }

    func testConnectionLostBannerOnWideConversation() {
        let presentation = UserFacingError(rawMessage: L10n.text("ui.approval_failed_websocket_not_connected"))
        assertSnapshot(
            of: host(width: 820, height: 120, colorScheme: .light) {
                ErrorPresentationBanner(
                    presentation: presentation,
                    isReconnecting: false,
                    onReconnect: {},
                    onDismiss: {}
                )
            },
            as: .image(precision: 0.98, layout: .fixed(width: 820, height: 120))
        )
    }

    func testHostErrorBannerWrapsActionsOnIPhoneDark() {
        let presentation = UserFacingError(AgentAPIError.server(status: 500, message: "internal error"))
        assertSnapshot(
            of: host(width: 390, height: 170, colorScheme: .dark) {
                ErrorPresentationBanner(
                    presentation: presentation,
                    isReconnecting: false,
                    onReconnect: {},
                    onDismiss: {}
                )
            },
            as: .image(precision: 0.98, layout: .fixed(width: 390, height: 170))
        )
    }

    func testFailureToastWithRetryAndExpandedDetailsOnIPhone() {
        let feedback = OperationFeedback(
            kind: .failure,
            message: L10n.format("ui.context_compression_failed_value", L10n.text("ui.error_timed_out")),
            technicalDetail: "app-server request timeout thread/compact/start #42",
            retry: OperationFeedback.Retry(title: L10n.text("ui.retry")) {}
        )
        assertSnapshot(
            of: host(width: 390, height: 300, colorScheme: .light) {
                InAppToastCard(
                    toast: InAppToast(feedback: feedback) { _ in },
                    showsDetail: .constant(true),
                    onDismiss: {}
                )
            },
            as: .image(precision: 0.98, layout: .fixed(width: 390, height: 300))
        )
    }

    func testInfoToastOnWideDark() {
        let feedback = OperationFeedback(kind: .info, message: L10n.text("ui.goal_updated"))
        assertSnapshot(
            of: host(width: 560, height: 110, colorScheme: .dark) {
                InAppToastCard(
                    toast: InAppToast(feedback: feedback) { _ in },
                    showsDetail: .constant(false),
                    onDismiss: {}
                )
            },
            as: .image(precision: 0.98, layout: .fixed(width: 560, height: 110))
        )
    }

    /// #738：会话页的常驻卡片与轻提示同一套版式（图标列、粗体标题、右上角关闭、按钮在下）。
    func testCompactHistoryCardOnIPhoneDark() {
        assertSnapshot(
            of: host(width: 390, height: 130, colorScheme: .dark) {
                InlineNoticeCard(
                    tone: .neutral,
                    systemImage: "doc.text.magnifyingglass",
                    title: L10n.text("ui.currently_showing_abbreviated_history"),
                    onClose: {}
                ) {
                    Button {} label: {
                        Label(L10n.text("ui.load_full_history"), systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            },
            as: .image(precision: 0.98, layout: .fixed(width: 390, height: 130))
        )
    }

    func testQuotaCardOnIPhoneLight() {
        assertSnapshot(
            of: host(width: 390, height: 150, colorScheme: .light) {
                InlineNoticeCard(
                    tone: .warning,
                    systemImage: "speedometer",
                    title: L10n.text("ui.quota_has_been_exhausted"),
                    subtitle: L10n.text("ui.this_sending_was_blocked_by_codex_quota_limit"),
                    onClose: {}
                ) {
                    Button {} label: {
                        Label(L10n.text("ui.refresh_status"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            },
            as: .image(precision: 0.98, layout: .fixed(width: 390, height: 150))
        )
    }

    func testRenameFailureFootnoteInForm() {
        let failure = UserFacingError(URLError(.cannotConnectToHost))
        let feedback = OperationFeedback(
            kind: .failure,
            message: L10n.format("ui.rename_failed_value", failure.message),
            technicalDetail: failure.technicalDetail
        )
        assertSnapshot(
            of: host(width: 540, height: 260, colorScheme: .light, padding: 0) {
                Form {
                    Section {
                        TextField(L10n.text("ui.enter_name"), text: .constant("新的会话名称"))
                    } header: {
                        Text(L10n.text("ui.session_name"))
                    } footer: {
                        OperationFailureFootnote(feedback: feedback)
                    }
                }
            },
            as: .image(precision: 0.98, layout: .fixed(width: 540, height: 260))
        )
    }

    private func host<Content: View>(
        width: CGFloat,
        height: CGFloat,
        colorScheme: ColorScheme,
        padding: CGFloat = 16,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let suiteName = "OperationFeedbackSnapshotTests.Theme.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let themeStore = ThemeStore(defaults: defaults)
        themeStore.mode = colorScheme == .dark ? .dark : .light
        let tokens = themeStore.tokens(for: colorScheme)

        return content()
            .environmentObject(themeStore)
            .environment(\.colorScheme, colorScheme)
            .environment(\.horizontalSizeClass, width < 600 ? .compact : .regular)
            .padding(padding)
            .frame(width: width, height: height, alignment: .top)
            .background(tokens.background)
    }
}

import SnapshotTesting
import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

/// #738：一次性提示落在导航栏和会话页状态卡片下方。
///
/// 位置来自真实 UINavigationBar 的下沿和页面登记的常驻区域，所以必须放进窗口里渲染；
/// 离屏 SwiftUI 快照没有导航栏，也等不到几何回调。
@MainActor
final class InAppNoticePlacementSnapshotTests: SimplifiedChineseSnapshotTestCase {
    func testToastClearsNavigationBarAndStatusCardOnIPhoneDark() async throws {
        let size = CGSize(width: 390, height: 420)
        let image = try await renderInWindow(size: size) {
            NavigationStack(path: .constant([1])) {
                Color.clear
                    .navigationDestination(for: Int.self) { _ in
                        self.conversationLikePage
                    }
            }
            .inAppToast(
                InAppToast(feedback: OperationFeedback(kind: .info, message: L10n.text("ui.goal_updated"))) { _ in },
                onDismiss: { _ in }
            )
            .inAppNoticePlacementScope()
        }
        assertSnapshot(of: image, as: .image(precision: 0.98))
    }

    private var conversationLikePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 代表会话页顶部状态条：卡片里有用户要点的按钮。
            ErrorPresentationBanner(
                presentation: UserFacingError(rawMessage: L10n.text("ui.approval_failed_websocket_not_connected")),
                isReconnecting: false,
                onReconnect: {},
                onDismiss: {}
            )
            .inAppNoticeProtectedRegion()
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)
            ForEach(0..<6, id: \.self) { index in
                Text(L10n.format("ui.session_renamed_to_value", "\(index)"))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            Spacer(minLength: 0)
        }
        .navigationTitle(L10n.text("ui.session"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {} label: { Image(systemName: "ellipsis") }
            }
        }
    }

    private func renderInWindow<Content: View>(
        size: CGSize,
        @ViewBuilder content: () -> Content
    ) async throws -> UIImage {
        let suiteName = "InAppNoticePlacementSnapshotTests.Theme.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let themeStore = ThemeStore(defaults: defaults)
        themeStore.mode = .dark
        let tokens = themeStore.tokens(for: .dark)

        let host = UIHostingController(
            rootView: content()
                .environmentObject(themeStore)
                .environment(\.colorScheme, .dark)
                .environment(\.horizontalSizeClass, .compact)
                .background(tokens.background)
        )
        host.overrideUserInterfaceStyle = .dark
        host.safeAreaRegions = []
        let windowScene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        host.view.frame = window.bounds
        // 等导航栏布局、卡片登记几何、提示重新测量这几轮更新落定。
        for _ in 0..<30 {
            host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 16_000_000)
        }
        return UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
    }
}

import SwiftUI
import UIKit

/// App 在前台时代替系统横幅的回复提醒（#510），复用 #508 的通用 App 内轻提示
/// （`View.inAppToast`），不另造浮层：位置、自动收起、上滑关闭、VoiceOver 播报与
/// Reduce Motion 都由它负责，这里只负责把通知映射成提示内容并登记宿主状态。
extension View {
    func foregroundSessionNoticeToasts() -> some View {
        modifier(ForegroundSessionNoticeToastHost())
    }
}

extension InAppToast {
    /// 前台回复提醒停留得比操作反馈稍久：它来自用户没在看的会话，需要时间读完再决定是否跳转。
    static let foregroundNoticeDuration: TimeInterval = 5

    init(notice: ForegroundSessionNotice, onOpen: @escaping @MainActor () -> Void) {
        let style: Style
        let systemImage: String?
        switch notice.tone {
        case .completed:
            style = .success
            systemImage = nil
        case .failed:
            style = .failure
            systemImage = nil
        case .interrupted:
            style = .info
            systemImage = "stop.circle.fill"
        }
        self.init(
            id: notice.id,
            style: style,
            title: notice.title,
            subtitle: notice.body.isEmpty ? nil : notice.body,
            systemImage: systemImage,
            // 点按正文：宿主先收起，再走与点系统横幅相同的通知路由。
            tapAction: onOpen,
            duration: Self.foregroundNoticeDuration
        )
    }
}

private struct ForegroundSessionNoticeToastHost: ViewModifier {
    @EnvironmentObject private var adapter: SessionNotificationResponseAdapter
    @EnvironmentObject private var sessionStore: SessionStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var sceneID = UUID()
    @State private var hostWindow = WeakWindowBox()

    func body(content: Content) -> some View {
        content
            .background {
                HostWindowReader { window in
                    hostWindow.window = window
                }
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
            .inAppToast(visibleToast) { id in
                guard let id = id.base as? UUID else { return }
                adapter.dismissForegroundNotice(id)
            }
            .onAppear(perform: updateHostAvailability)
            .onChange(of: scenePhase) { _, _ in
                updateHostAvailability()
            }
            .onDisappear {
                adapter.setInAppNoticeHostAvailable(false, for: sceneID)
            }
    }

    private var visibleToast: InAppToast? {
        // 多窗口时只由负责的那个窗口显示，避免同一条提醒在每个窗口各播报一次。
        guard let notice = adapter.foregroundNotice,
              notice.hostSceneID == nil || notice.hostSceneID == sceneID,
              !operationFeedbackIsVisible else {
            return nil
        }
        return InAppToast(notice: notice) { [adapter] in
            Task { await adapter.openForegroundNotice(notice) }
        }
    }

    /// 与 `OperationFeedbackToastHost` 的显示条件一致：操作反馈是用户刚做的事的结果，
    /// 先让它显示完，回复提醒排在后面，两条提示不会叠在同一位置。
    private var operationFeedbackIsVisible: Bool {
        guard let feedback = sessionStore.operationFeedback else { return false }
        return feedback.message != sessionStore.errorPresentation?.message
    }

    /// 只有 active 的 Scene 才登记：下拉通知中心或控制中心时 Scene 变为 inactive，用户看的是
    /// 系统界面，回复通知应回到系统横幅。轻提示叠在工作台上，盖着 sheet、弹窗等模态页面时
    /// 看不到，通知到达时同样交回系统横幅。
    private func updateHostAvailability() {
        let box = hostWindow
        adapter.setInAppNoticeHostAvailable(scenePhase == .active, for: sceneID) {
            // 还拿不到窗口时无法确认没有被遮挡，按看不到处理，交回系统横幅。
            guard let window = box.window else { return false }
            return window.rootViewController?.presentedViewController == nil
        }
    }
}

@MainActor
private final class WeakWindowBox {
    weak var window: UIWindow?
}

/// 只为拿到工作台所在的 UIWindow；本身不参与布局和命中。
private struct HostWindowReader: UIViewRepresentable {
    let onWindowChange: (UIWindow) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        view.onWindowChange = onWindowChange
        return view
    }

    func updateUIView(_ uiView: ReaderView, context: Context) {
        uiView.onWindowChange = onWindowChange
    }

    final class ReaderView: UIView {
        var onWindowChange: ((UIWindow) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window else { return }
            onWindowChange?(window)
        }
    }
}

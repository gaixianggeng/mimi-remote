import Combine
import Foundation
#if canImport(UIKit)
import UIKit
#endif

// 评分邀请（#842）的信号接入。规则与计数都在 AppReviewPromptCoordinator；
// 这里只把 SessionStore 已有的事件转交过去，`appReviewPrompt` 为 nil 时全部空转。
extension SessionStore {
    func noteAppReviewSignals(for event: AgentEvent, fallbackSessionID: SessionID) {
        guard let appReviewPrompt else { return }
        switch event {
        case .turnCompleted(let metadata):
            let sessionID = metadata.sessionID ?? fallbackSessionID
            // 与 EventReducer 一致：未带终态的完成事件按正常完成处理。
            appReviewPrompt.recordTurnFinished(
                sessionID: sessionID,
                turnID: metadata.turnID,
                lifecycle: metadata.turnLifecycle ?? .completed,
                isSessionVisible: sessionID == selectedSessionID && !isAppInBackground
            )
        case .error:
            appReviewPrompt.recordSetback()
        default:
            break
        }
    }

    func noteAppReviewApprovalAccepted(session: AgentSession) {
        appReviewPrompt?.recordApprovalAccepted(sessionID: session.id, turnID: session.activeTurnID)
    }

    /// 当前打开的输入框里有未发送的文字或附件。
    var hasAppReviewBlockingComposerDraft: Bool {
        let scope = ComposerDraftScopeKey.current(
            selectedSessionID: selectedSessionID,
            selectedProjectID: selectedProjectID
        )
        return !composerDraft(for: scope).isEmpty
    }
}

extension AppReviewPromptCoordinator {
    /// 线上实例。Mac 上运行（Catalyst 或 iPad App on Mac）、单元测试宿主和 Debug 启动参数
    /// 驱动的界面测试都不启用：只邀请 iOS App 的评分，也避免系统评分框盖住自动化界面。
    static func makeLive(appStore: AppStore, sessionStore: SessionStore) -> AppReviewPromptCoordinator? {
        guard isEnabled(processInfo: .processInfo) else { return nil }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let coordinator = AppReviewPromptCoordinator(appVersion: version ?? "")
#if canImport(UIKit)
        let textInputMonitor = TextInputEditingMonitor()
        coordinator.isUserTyping = { [weak sessionStore] in
            textInputMonitor.isEditing || sessionStore?.hasAppReviewBlockingComposerDraft == true
        }
#endif
        // 冷启动预热窗口内的探测失败会自动重试，界面也不展示；窗口结束后仍失败才算连接失败。
        coordinator.observeConnectionFailures(
            appStore.$connectionStatus
                .combineLatest(sessionStore.$isConnectionWarmUpActive)
                .receive(on: DispatchQueue.main)
                .map { [weak appStore, weak sessionStore] _ in
                    guard let appStore, let sessionStore,
                          case .failed = appStore.connectionStatus
                    else {
                        return false
                    }
                    return !sessionStore.isEstablishingConnection
                }
        )
        return coordinator
    }

    static func isEnabled(processInfo: ProcessInfo) -> Bool {
#if targetEnvironment(macCatalyst)
        return false
#else
        if processInfo.isiOSAppOnMac || processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return false
        }
#if DEBUG
        if processInfo.arguments.contains(where: { $0.hasPrefix("--debug-") || $0.hasPrefix("--test-") }) {
            return false
        }
#endif
        return true
#endif
    }
}

#if canImport(UIKit)
/// App 内是否有文本输入正处于编辑状态。软键盘和外接键盘都会发出开始/结束编辑通知，
/// 比键盘显隐更能代表「正在输入」。只记弱引用，读取时再核对仍是第一响应者。
@MainActor
final class TextInputEditingMonitor {
    private let editingInputs = NSHashTable<AnyObject>.weakObjects()
    private var observerTokens: [NSObjectProtocol] = []

    init(center: NotificationCenter = .default) {
        let names: [(Notification.Name, Bool)] = [
            (UITextField.textDidBeginEditingNotification, true),
            (UITextView.textDidBeginEditingNotification, true),
            (UITextField.textDidEndEditingNotification, false),
            (UITextView.textDidEndEditingNotification, false),
        ]
        observerTokens = names.map { name, began in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let input = notification.object as AnyObject?
                MainActor.assumeIsolated {
                    guard let self, let input else { return }
                    if began {
                        self.editingInputs.add(input)
                    } else {
                        self.editingInputs.remove(input)
                    }
                }
            }
        }
    }

    var isEditing: Bool {
        editingInputs.allObjects.contains { ($0 as? UIResponder)?.isFirstResponder == true }
    }
}
#endif

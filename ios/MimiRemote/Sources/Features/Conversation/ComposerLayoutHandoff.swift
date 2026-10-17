import SwiftUI
import UIKit

/// 外壳跨过 860pt 换树时，正在编辑的输入框和它打开的面板会随旧树一起销毁（#755）。
/// 换树前由外壳记下当时的焦点与面板，新树里同一草稿范围的输入框出现时恢复。
@MainActor
final class ComposerLayoutHandoff {
    enum Panel: Equatable {
        case model
        case addContent
    }

    struct Snapshot: Equatable {
        let scope: ComposerDraftScopeKey
        let isEditing: Bool
        let panel: Panel?
    }

    /// 新输入框通常在换树的下一帧出现。过期的记录不再恢复，
    /// 免得之后切回同一会话时意外弹出键盘或面板。
    static let restoreWindow: TimeInterval = 3

    // 换树时新输入框可能先于旧输入框的 onDisappear 登记，sheet 里也可能同时有另一个输入框。
    private var composers: [UUID: () -> Snapshot] = [:]
    private var pending: (snapshot: Snapshot, capturedAt: Date)?

    func register(_ id: UUID, snapshot: @escaping () -> Snapshot) {
        composers[id] = snapshot
    }

    func unregister(_ id: UUID) {
        composers[id] = nil
    }

    /// 只在换树前调用：此时旧输入框仍在窗口里，焦点和面板都是真实状态。
    func capture(now: Date = Date()) {
        let snapshots = composers.values.map { $0() }
        guard let snapshot = snapshots.first(where: \.isEditing)
            ?? snapshots.first(where: { $0.panel != nil }) else {
            pending = nil
            return
        }
        pending = (snapshot, now)
    }

    /// 下一个出现的输入框总会清掉记录；只有草稿范围一致且未过期才返回要恢复的状态。
    func consume(scope: ComposerDraftScopeKey, now: Date = Date()) -> Snapshot? {
        guard let pending else { return nil }
        self.pending = nil
        guard pending.snapshot.scope == scope,
              now.timeIntervalSince(pending.capturedAt) <= Self.restoreWindow else {
            return nil
        }
        return pending.snapshot
    }
}

extension ComposerLayoutHandoff {
    /// 沿呈现链找正在退场的控制器，等它的转场结束再执行；没有退场中的呈现则立即执行。
    static func afterPendingDismissal(in window: UIWindow?, perform action: @escaping () -> Void) {
        let root = window?.rootViewController
            ?? UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first?
                .rootViewController
        var controller = root?.presentedViewController
        while let current = controller {
            if current.isBeingDismissed, let coordinator = current.transitionCoordinator {
                coordinator.animate(alongsideTransition: nil) { _ in
                    // 完成回调里 UIKit 还没清掉 presentedViewController；下一轮再呈现。
                    DispatchQueue.main.async(execute: action)
                }
                return
            }
            controller = current.presentedViewController
        }
        action()
    }
}

private struct ComposerLayoutHandoffKey: EnvironmentKey {
    static let defaultValue: ComposerLayoutHandoff? = nil
}

extension EnvironmentValues {
    var composerLayoutHandoff: ComposerLayoutHandoff? {
        get { self[ComposerLayoutHandoffKey.self] }
        set { self[ComposerLayoutHandoffKey.self] = newValue }
    }
}

extension ComposerView {
    var layoutHandoffSnapshot: ComposerLayoutHandoff.Snapshot {
        let panel: ComposerLayoutHandoff.Panel? = if showsModelGridPicker {
            .model
        } else if showsAddContentPanel {
            .addContent
        } else {
            nil
        }
        return ComposerLayoutHandoff.Snapshot(
            scope: activeComposerDraftScope,
            isEditing: composerTextSubmitBridge.isEditing,
            panel: panel
        )
    }

    /// 在 onAppear 里、草稿范围切换之后调用。
    func attachLayoutHandoff() {
        guard let handoff = composerLayoutHandoff else { return }
        handoff.register(composerInstanceID) { layoutHandoffSnapshot }
        guard let snapshot = handoff.consume(scope: activeComposerDraftScope) else { return }
        if snapshot.isEditing {
            // 复用“点开输入框”的一次性焦点请求，由新的 UITextView 自己接手第一响应者。
            expandComposer()
        }
        guard let panel = snapshot.panel else { return }
        // 旧树里的同一面板正随换树做退场转场。此时呈现会被 UIKit 拒绝，SwiftUI 随即把状态复位，
        // 所以等退场结束，再锚定到新位置的按钮上打开。
        DispatchQueue.main.async {
            ComposerLayoutHandoff.afterPendingDismissal(in: composerTextSubmitBridge.hostWindow) {
                switch panel {
                case .model:
                    guard composerTurnSettingsPolicy.allowsTurnSettingsEditing else { return }
                    showsModelGridPicker = true
                case .addContent:
                    showsAddContentPanel = true
                }
            }
        }
    }
}

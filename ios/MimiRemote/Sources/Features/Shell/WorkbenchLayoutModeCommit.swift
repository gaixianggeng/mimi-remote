import SwiftUI
import UIKit

/// 紧凑导航与侧栏布局是两棵不同的视图树，跨过 860pt 时整棵重建（#755）。
///
/// 旋转时系统在尺寸过渡的动画块里同步更新尺寸。若在这次更新里换树，新建的导航容器、
/// 列表和托管视图会被 UIKit 从零尺寸动画到最终位置：整屏先空白，正文再从角落长出来。
/// 即使挪到动画块之外、但仍在过渡结束之前换树，新压入的会话页还会被过渡的收尾布局
/// 再动画一次（输入框从屏幕下方滑上来）。
///
/// 所以尺寸变化的那一轮只让已提交的那棵树按新尺寸排版，换树等系统尺寸过渡结束后再提交
/// （窗口拖动的每一步也是一次过渡）；没有过渡的变化（设置 sheet 关闭后补切）在下一轮主线程提交。
/// 提交后立即在无动画上下文里排版，不把建树留给之后任意一次可能处在动画块里的布局。
@MainActor
final class WorkbenchLayoutModeCommitGate {
    typealias Scheduler = (@escaping @MainActor () -> Void) -> Void

    private let schedule: Scheduler
    /// 观察者控制器的视图，用来找到所在窗口。
    weak var hostView: UIView?
    private var activeSizeTransitions = 0
    private var pendingCommit: (() -> Void)?
    private var revision: UInt = 0

    init(schedule: @escaping Scheduler = { action in
        DispatchQueue.main.async { MainActor.assumeIsolated(action) }
    }) {
        self.schedule = schedule
    }

    /// 同一轮里可能来回越过分界；只保留最后一次请求。
    func request(_ commit: @escaping () -> Void) {
        revision &+= 1
        let requestedRevision = revision
        pendingCommit = commit
        schedule { [weak self] in
            guard let self, self.revision == requestedRevision else { return }
            self.flushIfIdle()
        }
    }

    /// 返回过渡结束时调用的闭包；重复调用只生效一次。
    func sizeTransitionWillBegin() -> () -> Void {
        activeSizeTransitions += 1
        var didEnd = false
        return { [weak self] in
            guard let self, !didEnd else { return }
            didEnd = true
            self.activeSizeTransitions -= 1
            self.flushIfIdle()
        }
    }

    /// SwiftUI 默认等下一次布局才建新树；那一次可能正好落在系统的窗口缩放动画块里，
    /// 新容器又会被从零尺寸动画出来。
    func layoutCommittedTreeWithoutAnimation() {
        guard let window = hostView?.window else { return }
        UIView.performWithoutAnimation {
            window.layoutIfNeeded()
        }
    }

    private func flushIfIdle() {
        guard activeSizeTransitions == 0, let commit = pendingCommit else { return }
        pendingCommit = nil
        commit()
    }
}

/// 不可见的子控制器，只用来接收宿主转发的 `viewWillTransition(to:with:)`。
struct WorkbenchSizeTransitionObserver: UIViewControllerRepresentable {
    let gate: WorkbenchLayoutModeCommitGate

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.gate = gate
        gate.hostView = controller.view
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.gate = gate
        gate.hostView = controller.view
    }

    final class Controller: UIViewController {
        weak var gate: WorkbenchLayoutModeCommitGate?

        override func loadView() {
            let view = UIView()
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
            self.view = view
        }

        override func viewWillTransition(
            to size: CGSize,
            with coordinator: UIViewControllerTransitionCoordinator
        ) {
            super.viewWillTransition(to: size, with: coordinator)
            guard let endTransition = gate?.sizeTransitionWillBegin() else { return }
            coordinator.animate(alongsideTransition: nil) { _ in
                endTransition()
            }
        }
    }
}

import Observation
import SwiftUI
import UIKit

enum ConversationTimelineScrollMode: Equatable {
    case initialPositioning
    case followingTail
    case readingHistory
}

enum ConversationTimelineScrollReason: String {
    case initial, snapshot, layout, media, user, expansion, historyAnchor
}

enum ConversationTimelineScrollTarget: Hashable {
    case tail
    case offset(CGFloat)
    case item(String)
    case anchorItem(String)
}

struct ConversationTimelineScrollCommand {
    let target: ConversationTimelineScrollTarget
    let animated: Bool
}

struct ConversationTimelineScrollCommandRecord {
    let scope: ScopedSessionID
    let revision: Int
    let inputGeneration: Int
    let reason: ConversationTimelineScrollReason
    let target: ConversationTimelineScrollTarget
    let contentOffsetY: CGFloat
    let contentHeight: CGFloat
}

/// 会话内唯一的程序滚动 owner。数据、布局和用户输入都在此决定，视图只执行命令。
@MainActor
@Observable
final class ConversationTimelineScrollController {
#if DEBUG
    static var testingCommandObserver: ((ConversationTimelineScrollCommandRecord) -> Void)?
#endif

    private(set) var mode: ConversationTimelineScrollMode = .initialPositioning
    private(set) var isInteracting = false
    private(set) var isReadable = false
    private(set) var isNearBottom = true
    private(set) var hasUnseenTail = false
    private(set) var epoch = 0

    @ObservationIgnored let viewport = ConversationTimelineViewport()
    @ObservationIgnored private(set) var scope: ScopedSessionID?
    @ObservationIgnored private(set) var revision = 0
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var hasContent = false
    @ObservationIgnored private var tail: ConversationTimelineTailDescriptor?
    @ObservationIgnored private var rowIDs: [String] = []
    @ObservationIgnored private var metrics: ConversationTimelineScrollMetrics?
    @ObservationIgnored private var interactionStartOffset: CGFloat?
    @ObservationIgnored private var ownsAnimation = false
    @ObservationIgnored private var isTailVisible = false
    @ObservationIgnored private var attemptedInitialPosition = false
    @ObservationIgnored private var inputGeneration = 0
    @ObservationIgnored private var anchor: ConversationTimelineViewport.Anchor?
    @ObservationIgnored private var anchorFallbackItemID: String?
    @ObservationIgnored private var pending: Pending?
    @ObservationIgnored private var pendingTask: Task<Void, Never>?
    @ObservationIgnored private var anchorExpirationTask: Task<Void, Never>?
    @ObservationIgnored private var expansion: (input: Int, targetID: String?)?
    @ObservationIgnored private var execute: ((ConversationTimelineScrollCommand) -> Void)?
    @ObservationIgnored private var appliedCommands: Set<CommandKey> = []

    private enum Pending {
        case tail(animated: Bool, reason: ConversationTimelineScrollReason)
        case anchor
        case item(String)
        case revealItem(String)
    }

    private struct LayoutKey: Hashable {
        let height: CGFloat
        let minimum: CGFloat
        let maximum: CGFloat

        init(_ metrics: ConversationTimelineScrollMetrics) {
            height = metrics.contentHeight
            minimum = metrics.minimumOffsetY
            maximum = metrics.maximumOffsetY
        }
    }

    private struct CommandKey: Hashable {
        let target: ConversationTimelineScrollTarget
        let layout: LayoutKey
    }

    /// 必须在新 rows 交给 List 之前调用，旧可见消息仍可用于建立本次更新的阅读锚点。
    @discardableResult
    func prepare(_ snapshot: ConversationTimelineSnapshot) -> Bool {
        guard let nextScope = snapshot.scope else { return false }
        if !isActive || scope != nextScope {
            reset(for: nextScope)
        } else if revision == snapshot.revision {
            return false
        }
        // idle 解冻可能先发布一份仅 revision 变化的快照，不能抹掉尚未执行的用户请求。
        let requestedTail: Bool
        if case .tail(_, .user) = pending { requestedTail = true } else { requestedTail = false }
        let firstContent = !hasContent && !snapshot.rows.isEmpty
        let structureChanged = rowIDs != snapshot.rowIDs
        let assistantTextChanged = snapshot.tail?.role == .assistant
            && tail?.renderFingerprint != snapshot.tail?.renderFingerprint
        let visibleTailChanged = structureChanged || assistantTextChanged
        let liveTailChanged = snapshot.changes.contains(.live) && visibleTailChanged
        beginInput()
        revision = snapshot.revision
        hasContent = !snapshot.rows.isEmpty
        tail = snapshot.tail
        rowIDs = snapshot.rowIDs
        if firstContent {
            // 空占位与正文是不同 List；即使 scope 相同，旧 List 的布局回调也必须失效。
            epoch += 1
            isInteracting = false
            interactionStartOffset = nil
            ownsAnimation = false
            viewport.reset()
            execute = nil
            mode = .initialPositioning
            isReadable = false
            attemptedInitialPosition = false
            isTailVisible = false
            metrics = nil
        } else if snapshot.changes.contains(.localSubmission) {
            // 来源层保留明确发送意图，即使同一批次的尾消息已经变成 assistant 也不能丢失。
            // 首屏尚未交接时仍须完成初始定位，不能跳过解除正文遮罩的唯一入口。
            mode = isReadable ? .followingTail : .initialPositioning
        }
        if snapshot.changes.contains(.presentation), isReadable {
            // 用户改变展开层级时固定阅读位置，即使之前贴底也不跳到新增内容末尾。
            mode = .readingHistory
        }
        if liveTailChanged, !snapshot.changes.contains(.presentation), mode == .readingHistory {
            hasUnseenTail = true
        }
        guard hasContent, !isInteracting else { return true }
        switch mode {
        case .initialPositioning:
            pending = .tail(animated: false, reason: .initial)
        case .followingTail:
            // 折叠命令的 stdout/status 更新不一定改变布局；真实行高变化由 geometry 接口报告。
            if requestedTail {
                pending = .tail(animated: true, reason: .user)
            } else if visibleTailChanged || snapshot.changes.containsHistoryChange || snapshot.changes.contains(.localSubmission) {
                pending = .tail(animated: snapshot.changes.contains(.localSubmission), reason: .snapshot)
            }
        case .readingHistory:
            captureAnchor(restoringRows: snapshot.changes.containsHistoryChange ? snapshot.rows : nil)
        }
        return true
    }

    func snapshotWasPublished() {
        schedulePending()
    }

    func connect(
        epoch expectedEpoch: Int,
        execute: @escaping (ConversationTimelineScrollCommand) -> Void
    ) {
        guard isActive, epoch == expectedEpoch else { return }
        self.execute = execute
        schedulePending()
    }

    func bind(scrollView: UIScrollView, epoch expectedEpoch: Int) {
        guard isActive, epoch == expectedEpoch else { return }
        viewport.bind(scrollView)
        schedulePending()
    }

    func geometryChanged(_ reported: ConversationTimelineScrollMetrics, epoch expectedEpoch: Int) {
        guard isActive, epoch == expectedEpoch else { return }
        let next = viewport.metrics ?? reported
        let previous = metrics
        ConversationScrollDiagnostics.shared.geometry(previous ?? next, next, interacting: isInteracting)
        metrics = next
        isNearBottom = next.isNearBottom
        if isInteracting {
            if let start = interactionStartOffset, next.contentOffsetY < start - 12 {
                mode = .readingHistory
            }
            return
        }
        // offset 是执行结果，不是新的滚动意图。只有实际布局尺寸变化才重新决策，
        // 因此 UIKit 回写同一 offset 不会触发“修改→观察→再修改”的反馈环。
        let layoutChanged = previous.map { LayoutKey($0) != LayoutKey(next) } ?? true
        if hasContent, layoutChanged {
            respondToLayoutChange()
        }
        confirmInitialPosition()
    }

    func anchorViewDidLayout(_ ids: [UUID], view: UIView, epoch expectedEpoch: Int) {
        guard isActive, epoch == expectedEpoch else { return }
        viewport.bindAnchorView(ids, view)
        if viewport.scrollView == nil, view.window != nil {
            var ancestor = view.superview
            while let candidate = ancestor {
                if let scrollView = candidate as? UIScrollView {
                    viewport.bind(scrollView)
                    break
                }
                ancestor = candidate.superview
            }
        }
        guard isReadable, !isInteracting, let current = viewport.metrics else { return }
        if mode == .readingHistory, let anchor, viewport.correctedOffset(for: anchor) != nil {
            // 按行 ID 找回消息后，重新绑定可能只改变可见 cell、不改变总高度。
            // 此时就在原生布局内完成精校，不等待下一拍 SwiftUI 几何通知。
            metrics = current
            pending = .anchor
            applyPending()
            return
        }
        // 首屏仍由 SwiftUI 完成交接；普通布局只消费尺寸变化，不观察 offset 回写。
        guard metrics.map({ LayoutKey($0) != LayoutKey(current) }) ?? true else { return }
        metrics = current
        respondToLayoutChange()
    }

    private func respondToLayoutChange() {
        switch mode {
        case .initialPositioning, .followingTail:
            if let targetID = expansion?.targetID {
                pending = .item(targetID)
            } else {
                pending = .tail(animated: false, reason: .layout)
            }
            applyPending()
        case .readingHistory:
            if anchor != nil {
                pending = .anchor
                applyPending()
            }
        }
    }

    func tailVisibilityChanged(_ visible: Bool, epoch expectedEpoch: Int) {
        guard isActive, epoch == expectedEpoch else { return }
        isTailVisible = visible
        confirmInitialPosition()
    }

    func phaseChanged(_ phase: ScrollPhase, epoch expectedEpoch: Int? = nil) {
        guard isActive, expectedEpoch == nil || expectedEpoch == epoch else { return }
        ConversationScrollDiagnostics.shared.record("phase", "\(phase)")
        let userDriven = Self.isUserDriven(phase) || (phase == .animating && !ownsAnimation)
        if userDriven, !isInteracting || phase == .tracking {
            isInteracting = true
            interactionStartOffset = metrics?.contentOffsetY ?? viewport.metrics?.contentOffsetY
            if phase == .animating { mode = .readingHistory }
            cancelPending()
            releaseAnchor()
            expansion = nil
        } else if phase == .idle {
            let wasInteracting = isInteracting
            isInteracting = false
            ownsAnimation = false
            interactionStartOffset = nil
            let reachedTail = metrics.map { abs($0.maximumOffsetY - $0.contentOffsetY) <= 4 } ?? false
            if wasInteracting, reachedTail {
                if isReadable { mode = .followingTail }
                hasUnseenTail = false
            }
            // 惯性中的显式点击等手势结束后执行；新 tracking 会在上方取消旧请求。
            if case .tail(_, .user) = pending {
                mode = isReadable ? .followingTail : .initialPositioning
                hasUnseenTail = false
                schedulePending()
            }
        }
    }

    static func isUserDriven(_ phase: ScrollPhase) -> Bool {
        switch phase {
        case .tracking, .interacting, .decelerating: true
        case .idle, .animating: false
        }
    }

    func mediaLayoutWillChange() {
        guard isActive, hasContent, !isInteracting else { return }
        beginInput()
        if mode == .readingHistory {
            captureAnchor()
        } else {
            pending = .tail(animated: false, reason: .media)
        }
        schedulePending()
    }

    func recordAnchorFrame(_ messageIDs: [UUID], _ frame: CGRect, epoch expectedEpoch: Int? = nil) {
        guard isActive, expectedEpoch == nil || expectedEpoch == epoch else { return }
        viewport.updateAnchorFrame(messageIDs, frame)
        guard anchor != nil, !isInteracting else { return }
        pending = .anchor
        schedulePending()
    }

    func returnToTail() {
        guard isActive, hasContent else { return }
        ConversationScrollDiagnostics.shared.record("return_tail")
        beginInput()
        pending = .tail(animated: true, reason: .user)
        guard !isInteracting else { return }
        mode = isReadable ? .followingTail : .initialPositioning
        hasUnseenTail = false
        schedulePending()
    }

    @discardableResult
    func expansionChanged(_ id: String, isExpanded: Bool, isAnimated: Bool = true) -> Int? {
        guard isActive, !isInteracting else { return nil }
        beginInput()
        let targetID = mode != .readingHistory && isExpanded && isNearBottom ? id : nil
        expansion = (inputGeneration, targetID)
        if mode == .readingHistory {
            // 展开由 SwiftUI 的动画完成回调结束，不能在 spring 结束前按网络更新超时撤销。
            captureAnchor(expires: false)
        } else if targetID != nil {
            pending = .item(id)
        } else {
            pending = .tail(animated: false, reason: .expansion)
        }
        // 无动画时 SwiftUI completion 会立即调用，早于新行布局；沿用单次布局的取消上限。
        if !isAnimated { scheduleAnchorExpiration() }
        schedulePending()
        return inputGeneration
    }

    func expansionCompleted(_ input: Int?) {
        guard let input, expansion?.input == input, inputGeneration == input else { return }
        if anchor != nil { pending = .anchor }
        applyPending()
        cancelPending()
        releaseAnchor()
        expansion = nil
    }

    func revealItem(_ id: String) {
        guard isActive, hasContent else { return }
        beginInput()
        mode = .readingHistory
        pending = .revealItem(id)
        schedulePending()
    }

    func beginLoadingEarlierHistory() {
        mode = .readingHistory
        beginInput()
    }

    func invalidate() {
        cancelPending()
        releaseAnchor()
        execute = nil
        viewport.reset()
        expansion = nil
        isActive = false
    }

    private func reset(for scope: ScopedSessionID) {
        invalidate()
        self.scope = scope
        epoch += 1
        revision = 0
        mode = .initialPositioning
        isInteracting = false
        isReadable = false
        isNearBottom = true
        hasUnseenTail = false
        hasContent = false
        tail = nil
        rowIDs = []
        metrics = nil
        isTailVisible = false
        attemptedInitialPosition = false
        ownsAnimation = false
        isActive = true
        ConversationScrollDiagnostics.shared.record("session_switch")
    }

    private func beginInput() {
        cancelPending()
        releaseAnchor()
        expansion = nil
        inputGeneration += 1
        appliedCommands.removeAll(keepingCapacity: true)
    }

    private func captureAnchor(expires: Bool = true, restoringRows: [ConversationTimelineItem]? = nil) {
        anchor = viewport.captureVisibleAnchor()
        guard let anchor else { return }
        if let restoringRows {
            // 以旧视口的候选顺序寻找新快照中的行，不让新页顺序或总高度决定阅读位置。
            for candidate in anchor.candidates {
                if let row = restoringRows.first(where: { $0.anchorMessageIDs.contains(candidate.id) }) {
                    anchorFallbackItemID = row.id
                    break
                }
            }
        }
        pending = .anchor
        ConversationScrollDiagnostics.shared.record("anchor_begin", "generation=\(inputGeneration)")
        guard expires else { return }
        scheduleAnchorExpiration()
    }

    private func scheduleAnchorExpiration() {
        let expectedInput = inputGeneration
        // 这是本次数据提交的取消上限，不是滚动重试。没有新输入时不能永久保留旧阅读锚点。
        anchorExpirationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, self.inputGeneration == expectedInput else { return }
            self.releaseAnchor()
            self.expansion = nil
        }
    }

    private func releaseAnchor() {
        if anchor != nil { ConversationScrollDiagnostics.shared.record("anchor_end") }
        anchor = nil
        anchorFallbackItemID = nil
        viewport.releaseAnchor()
        anchorExpirationTask?.cancel()
        anchorExpirationTask = nil
    }

    private func cancelPending() {
        pending = nil
        pendingTask?.cancel()
        pendingTask = nil
    }

    private func schedulePending() {
        guard pending != nil, pendingTask == nil, !isInteracting else { return }
        let expectedEpoch = epoch
        let expectedInput = inputGeneration
        pendingTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self,
                  self.epoch == expectedEpoch, self.inputGeneration == expectedInput else { return }
            self.pendingTask = nil
            self.applyPending(allowProxyScroll: true)
        }
    }

    private func applyPending(allowProxyScroll: Bool = false) {
        guard isActive, !isInteracting, !viewport.isUserScrolling,
              let pending, let execute, let scope,
              let current = metrics ?? viewport.metrics, current.contentHeight > 0 else { return }
        let target: ConversationTimelineScrollTarget
        let animated: Bool
        let reason: ConversationTimelineScrollReason
        switch pending {
        case let .tail(shouldAnimate, source):
            guard mode != .readingHistory else { self.pending = nil; return }
            target = .tail
            animated = shouldAnimate
            reason = mode == .initialPositioning ? .initial : source
        case .anchor:
            guard mode == .readingHistory, let anchor else { self.pending = nil; return }
            if let offset = viewport.correctedOffset(for: anchor), let native = viewport.metrics {
                guard abs(offset - native.contentOffsetY) >= 0.5 else { self.pending = nil; return }
                target = .offset((offset * 2).rounded() / 2)
            } else if let itemID = anchorFallbackItemID {
                // ScrollViewProxy 不能在 UIViewRepresentable 的更新/布局回调内使用。
                // 仍复用本控制器的合并任务，等本轮 SwiftUI 更新结束后再找回行。
                guard allowProxyScroll else { schedulePending(); return }
                // 整页前插可能回收所有旧候选。只按稳定行 ID 找回一次，等消息原生
                // 标记重新绑定后再精确保位，避免 contentSize 估算引入新的反馈循环。
                anchorFallbackItemID = nil
                target = .anchorItem(itemID)
            } else {
                self.pending = nil
                return
            }
            animated = false
            reason = .historyAnchor
        case let .revealItem(id):
            guard allowProxyScroll else { schedulePending(); return }
            target = .anchorItem(id)
            animated = false
            reason = .user
        case let .item(id):
            guard allowProxyScroll else { schedulePending(); return }
            target = .item(id)
            animated = false
            reason = .expansion
        }
        self.pending = nil
        let key = CommandKey(target: target, layout: LayoutKey(current))
        guard appliedCommands.insert(key).inserted else { return }
        if mode == .initialPositioning { attemptedInitialPosition = true }
        if animated { ownsAnimation = true }
#if DEBUG
        Self.testingCommandObserver?(ConversationTimelineScrollCommandRecord(
            scope: scope, revision: revision, inputGeneration: inputGeneration,
            reason: reason, target: target,
            contentOffsetY: current.contentOffsetY, contentHeight: current.contentHeight
        ))
#endif
        switch target {
        case .tail:
            ConversationScrollDiagnostics.shared.record("scroll_tail", "animated=\(animated) offset=\(Int(current.contentOffsetY)) generation=\(inputGeneration)")
        case let .offset(offset):
            ConversationScrollDiagnostics.shared.record("scroll_anchor", "from=\(Int(viewport.metrics?.contentOffsetY ?? current.contentOffsetY)) to=\(Int(offset)) generation=\(inputGeneration)")
        case .item:
            ConversationScrollDiagnostics.shared.record("scroll_expansion")
        case .anchorItem:
            ConversationScrollDiagnostics.shared.record("scroll_anchor_item")
        }
        execute(ConversationTimelineScrollCommand(target: target, animated: animated))
        // List 本来已在尾部时 scrollTo 不一定产生新回调；已有几何也必须能完成交接。
        confirmInitialPosition()
    }

    private func confirmInitialPosition() {
        guard mode == .initialPositioning, attemptedInitialPosition, isTailVisible,
              let current = viewport.metrics ?? metrics,
              abs(current.maximumOffsetY - current.contentOffsetY) <= 4 else { return }
        mode = .followingTail
        isReadable = true
        hasUnseenTail = false
        ConversationScrollDiagnostics.shared.record("initial_present", "height=\(Int(current.contentHeight))")
    }
}

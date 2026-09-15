import UIKit

/// 只读取 List 的实际布局并保存可见消息标记，不持有滚动策略、监听或异步任务。
@MainActor
final class ConversationTimelineViewport {
#if DEBUG
    static var testingFrameObserver: ((UUID, CGRect) -> Void)?
    static var testingSelectionObserver: ((UUID, CGRect) -> Void)?
    static var testingViewObserver: ((UUID, UIView) -> Void)?
#endif

    struct Anchor {
        let candidates: [(id: UUID, frame: CGRect)]
    }

    private struct WeakView {
        weak var value: UIView?
    }

    private(set) weak var scrollView: UIScrollView?
    private var frames: [UUID: CGRect] = [:]
    private var sharedFrameOrder: [UUID: Int] = [:]
    private var visibleIDs: Set<UUID> = []
    private var views: [UUID: WeakView] = [:]
    private var retainedIDs: Set<UUID> = []

    var metrics: ConversationTimelineScrollMetrics? {
        guard let scrollView else { return nil }
        let minimum = -scrollView.adjustedContentInset.top
        let maximum = max(minimum, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
        return ConversationTimelineScrollMetrics(
            isNearBottom: maximum - scrollView.contentOffset.y <= 120,
            contentOffsetY: scrollView.contentOffset.y,
            contentHeight: scrollView.contentSize.height,
            minimumOffsetY: minimum,
            maximumOffsetY: maximum
        )
    }

    var isUserScrolling: Bool {
        guard let scrollView else { return false }
        return scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
    }

    func bind(_ scrollView: UIScrollView) {
        if let previous = self.scrollView, previous !== scrollView {
            reset()
        }
        self.scrollView = scrollView
    }

    func bindAnchorView(_ messageIDs: [UUID], _ view: UIView) {
        for id in messageIDs {
            views[id] = WeakView(value: view)
#if DEBUG
            Self.testingViewObserver?(id, view)
#endif
        }
    }

    func updateAnchorFrame(_ messageIDs: [UUID], _ frame: CGRect) {
        for (index, id) in messageIDs.enumerated() {
            if frame.isNull {
                visibleIDs.remove(id)
                if !retainedIDs.contains(id) {
                    frames.removeValue(forKey: id)
                    sharedFrameOrder.removeValue(forKey: id)
                    views.removeValue(forKey: id)
                }
            } else {
                frames[id] = frame
                sharedFrameOrder[id] = index
                visibleIDs.insert(id)
#if DEBUG
                Self.testingFrameObserver?(id, frame)
#endif
            }
        }
    }

    func captureVisibleAnchor() -> Anchor? {
        releaseAnchor()
        guard let scrollView else { return nil }
        let visibleFrame = scrollView.convert(scrollView.bounds, to: nil)
        let candidates = visibleIDs.compactMap { id -> (id: UUID, frame: CGRect)? in
            guard let frame = currentFrame(for: id), frame.intersects(visibleFrame) else { return nil }
            return (id, frame)
        }.sorted { lhs, rhs in
            if lhs.frame.minY != rhs.frame.minY { return lhs.frame.minY < rhs.frame.minY }
            if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
            // 折叠组共享 frame 时按正文顺序选择首项，不能让随机 UUID 决定展开后的阅读位置。
            if sharedFrameOrder[lhs.id] != sharedFrameOrder[rhs.id] {
                return (sharedFrameOrder[lhs.id] ?? 0) < (sharedFrameOrder[rhs.id] ?? 0)
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        guard let first = candidates.first else { return nil }
        // 补齐可能删除摘要或暂时把首个候选移出屏幕，保留其他可见消息作为退路。
        retainedIDs = Set(candidates.map(\.id))
#if DEBUG
        Self.testingSelectionObserver?(first.id, first.frame)
#endif
        return Anchor(candidates: candidates)
    }

    func correctedOffset(for anchor: Anchor) -> CGFloat? {
        guard let metrics,
              let candidate = anchor.candidates.first(where: { currentFrame(for: $0.id) != nil }),
              let frame = currentFrame(for: candidate.id) else { return nil }
        // frame 与 offset 在同一 UIKit 时刻读取，不能再次补偿 List 已完成的自动保位。
        return Self.preservedOffset(
            currentOffsetY: metrics.contentOffsetY,
            currentAnchorMinY: frame.minY,
            baselineAnchorMinY: candidate.frame.minY,
            minimumOffsetY: metrics.minimumOffsetY,
            maximumOffsetY: metrics.maximumOffsetY
        )
    }

    static func preservedOffset(
        currentOffsetY: CGFloat,
        currentAnchorMinY: CGFloat,
        baselineAnchorMinY: CGFloat,
        minimumOffsetY: CGFloat,
        maximumOffsetY: CGFloat
    ) -> CGFloat {
        let corrected = currentOffsetY + currentAnchorMinY - baselineAnchorMinY
        return min(max(minimumOffsetY, maximumOffsetY), max(minimumOffsetY, corrected))
    }

    func releaseAnchor() {
        for id in retainedIDs where !visibleIDs.contains(id) {
            frames.removeValue(forKey: id)
            sharedFrameOrder.removeValue(forKey: id)
            views.removeValue(forKey: id)
        }
        retainedIDs.removeAll()
    }

    func reset() {
        scrollView = nil
        frames.removeAll()
        sharedFrameOrder.removeAll()
        visibleIDs.removeAll()
        views.removeAll()
        retainedIDs.removeAll()
    }

    private func currentFrame(for id: UUID) -> CGRect? {
        if let registered = views[id] {
            guard let view = registered.value, let scrollView,
                  view.isDescendant(of: scrollView), !view.bounds.isEmpty else { return nil }
            return view.convert(view.bounds, to: nil)
        }
        return frames[id]
    }
}

struct ConversationTimelineScrollMetrics: Equatable {
    let isNearBottom: Bool
    let contentOffsetY: CGFloat
    let contentHeight: CGFloat
    let minimumOffsetY: CGFloat
    let maximumOffsetY: CGFloat
}

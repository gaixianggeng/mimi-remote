import SwiftUI
import UIKit

/// 与消息内容同尺寸的原生标记，保位时同步读取实际布局，不依赖异步几何通知的先后次序。
struct ConversationHistoryAnchorView: UIViewRepresentable {
    let bind: (UIView) -> Void

    func makeUIView(context: Context) -> MarkerView {
        let view = MarkerView()
        view.isUserInteractionEnabled = false
        view.bind = bind
        return view
    }

    func updateUIView(_ uiView: MarkerView, context: Context) {
        uiView.bind = bind
        bind(uiView)
    }

    final class MarkerView: UIView {
        var bind: ((UIView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            bind?(self)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // 在原生布局提交中报告行高，不能依赖下一拍 SwiftUI geometry 才纠正可读画面。
            bind?(self)
        }
    }
}

private struct ConversationMediaLayoutWillChangeKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}

private struct ConversationTimelineIsScrollingKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ConversationBindAnchorViewKey: EnvironmentKey {
    static let defaultValue: @MainActor ([UUID], UIView) -> Void = { _, _ in }
}

extension EnvironmentValues {
    var conversationBindAnchorView: @MainActor ([UUID], UIView) -> Void {
        get { self[ConversationBindAnchorViewKey.self] }
        set { self[ConversationBindAnchorViewKey.self] = newValue }
    }

    var conversationMediaLayoutWillChange: @MainActor () -> Void {
        get { self[ConversationMediaLayoutWillChangeKey.self] }
        set { self[ConversationMediaLayoutWillChangeKey.self] = newValue }
    }

    var conversationTimelineIsScrolling: Bool {
        get { self[ConversationTimelineIsScrollingKey.self] }
        set { self[ConversationTimelineIsScrollingKey.self] = newValue }
    }
}

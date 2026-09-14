import SwiftUI
import UIKit

/// 与消息内容同尺寸的原生标记，保位时同步读取实际布局，不依赖异步几何通知的先后次序。
struct ConversationHistoryAnchorView: UIViewRepresentable {
    let bind: (UIView) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        bind(uiView)
    }
}

private struct ConversationMediaLayoutWillChangeKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}

private struct ConversationTimelineIsScrollingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var conversationMediaLayoutWillChange: @MainActor () -> Void {
        get { self[ConversationMediaLayoutWillChangeKey.self] }
        set { self[ConversationMediaLayoutWillChangeKey.self] = newValue }
    }

    var conversationTimelineIsScrolling: Bool {
        get { self[ConversationTimelineIsScrollingKey.self] }
        set { self[ConversationTimelineIsScrollingKey.self] = newValue }
    }
}

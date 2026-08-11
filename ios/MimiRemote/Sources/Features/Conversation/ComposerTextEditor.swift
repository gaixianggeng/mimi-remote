import SwiftUI
import UIKit

struct TextSelectionPolicy {
    static func rangeAfterExternalTextSync(previousText: String, nextText: String, previousRange: NSRange) -> NSRange {
        let previousLength = utf16Length(of: previousText)
        let nextLength = utf16Length(of: nextText)
        let caretWasAtPreviousEnd = previousRange.length == 0 && previousRange.location >= previousLength
        if caretWasAtPreviousEnd {
            return NSRange(location: nextLength, length: 0)
        }
        return clampedRange(previousRange, in: nextText)
    }

    static func clampedRange(_ range: NSRange, in text: String) -> NSRange {
        let length = utf16Length(of: text)
        let location = min(max(0, range.location), length)
        let remaining = max(0, length - location)
        return NSRange(location: location, length: min(max(0, range.length), remaining))
    }

    private static func utf16Length(of text: String) -> Int {
        (text as NSString).length
    }
}

struct ComposerTextSubmitSnapshot {
    let text: String
    let isComposing: Bool
}

final class ComposerTextSubmitBridge {
    private weak var textView: CommandSubmitTextView?

    private var activeTextView: CommandSubmitTextView? {
        guard let textView, !textView.isRetiredFromComposer else {
            return nil
        }
        return textView
    }

    func attach(_ textView: CommandSubmitTextView) {
        self.textView = textView
    }

    func snapshotForSubmit() -> ComposerTextSubmitSnapshot? {
        guard let textView = activeTextView else {
            return nil
        }
        return ComposerTextSubmitSnapshot(
            text: textView.text ?? "",
            isComposing: textView.hasMarkedText
        )
    }

    func hasNonWhitespaceTextForSubmit() -> Bool {
        guard let text = activeTextView?.text else {
            return false
        }
        return text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted) != nil
    }

    func finalSnapshotForSubmit() -> ComposerTextSubmitSnapshot? {
        guard let textView = activeTextView else {
            return nil
        }
        // 最终发送采用“单击即确认”的策略：先让输入法提交 marked text，再读取
        // UITextView 的权威文本，避免 SwiftUI 草稿仍停留在上一次已确认内容。
        commitMarkedTextIfNeeded(in: textView)
        return ComposerTextSubmitSnapshot(
            text: textView.text ?? "",
            isComposing: textView.hasMarkedText
        )
    }

    func resignFirstResponder() {
        activeTextView?.resignFirstResponder()
    }

    func resetTextAfterSubmit(to text: String) {
        guard let textView = activeTextView else { return }
        // iPhone 发送后继续复用同一个 UITextView。先把 UIKit 的权威文本同步为空，
        // 再结束编辑，避免 textViewDidEndEditing 把刚发送的旧正文重新写回草稿。
        textView.text = text
        textView.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        textView.resignFirstResponder()
    }

    func prepareForRemoval(text: String) {
        guard let textView = activeTextView else { return }
        // 先退休旧编辑器，再清空/失焦。iPhone 发送后会立即替换整个输入卡片，
        // 输入法和 TextKit 仍可能补发 delegate 回调；这些回调不得把已发送文本写回草稿。
        textView.retireFromComposer()
        textView.text = text
        textView.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        textView.resignFirstResponder()
    }

    func replaceText(in range: NSRange, with replacement: String) -> String? {
        guard let textView = activeTextView else {
            return nil
        }
        // Skill 自动补全会直接改写 TextKit；先结束旧的组合态，防止替换后
        // markedTextRange 残留，造成按钮状态与最终提交快照分叉。
        commitMarkedTextIfNeeded(in: textView)
        guard range.location >= 0,
              NSMaxRange(range) <= ((textView.text ?? "") as NSString).length
        else {
            return nil
        }
        textView.textStorage.replaceCharacters(in: range, with: replacement)
        textView.selectedRange = NSRange(location: range.location + (replacement as NSString).length, length: 0)
        textView.delegate?.textViewDidChange?(textView)
        return textView.text
    }

    private func commitMarkedTextIfNeeded(in textView: CommandSubmitTextView) {
        guard textView.hasMarkedText else {
            return
        }
        textView.unmarkText()
    }
}

enum ComposerFocusRequestPolicy {
    static func requestToConsume(pending: UUID?, lastHandled: UUID?) -> UUID? {
        guard let pending, pending != lastHandled else {
            return nil
        }
        return pending
    }

    static func pendingRequest(afterConsuming consumed: UUID, current: UUID?) -> UUID? {
        // becomeFirstResponder 异步执行期间可能来了一个更新的请求，旧回调不能把新 token 一起清掉。
        current == consumed ? nil : current
    }
}

struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let submitBridge: ComposerTextSubmitBridge
    let font: UIFont
    let textColor: UIColor
    let tintColor: UIColor
    let externalTextRevision: Int
    @Binding var focusRequestID: UUID?
    let minHeight: CGFloat
    let maxHeight: CGFloat
    var textContainerInset: UIEdgeInsets = .zero
    let onSubmit: () -> Bool
    let onContentHeightChange: (CGFloat) -> Void
    let onCompositionStateChange: (Bool) -> Void
    let onVoiceShortcutPressChanged: (Bool) -> Void
    let skillAutocompleteActive: Bool
    let onSkillQueryChange: (ComposerSkillQuery?) -> Void
    let onSkillAutocompleteMove: (Int) -> Void
    let onSkillAutocompleteCommit: () -> Void
    let onSkillAutocompleteDismiss: () -> Void

    func makeUIView(context: Context) -> CommandSubmitTextView {
        let textView = CommandSubmitTextView()
        textView.onRetireFromComposer = { [weak coordinator = context.coordinator] in
            coordinator?.retireFromComposer()
        }
        textView.text = text
        context.coordinator.lastSyncedText = text
        context.coordinator.lastAppliedExternalRevision = externalTextRevision
        submitBridge.attach(textView)
        textView.onCommandSubmit = onSubmit
        textView.onContentLayoutChanged = { textView in
            context.coordinator.reportContentHeight(for: textView)
        }
        textView.onVoiceShortcutPressChanged = onVoiceShortcutPressChanged
        textView.isSkillAutocompleteActive = skillAutocompleteActive
        textView.onSkillAutocompleteMove = onSkillAutocompleteMove
        textView.onSkillAutocompleteCommit = onSkillAutocompleteCommit
        textView.onSkillAutocompleteDismiss = onSkillAutocompleteDismiss
        textView.backgroundColor = .clear
        textView.font = font
        textView.textColor = textColor
        textView.tintColor = tintColor
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = false
        textView.showsVerticalScrollIndicator = true
        textView.textContainerInset = textContainerInset
        textView.textContainer.lineFragmentPadding = 0
        textView.keyboardDismissMode = .interactive
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.accessibilityLabel = L10n.text("ui.enter_tasks_or_follow_up_instructions")
        // 真机端到端验收需要稳定定位真实输入控件；identifier 只服务可访问性与 UI 测试，
        // 不改变 UITextView 的焦点、提交或草稿同步语义。
        textView.accessibilityIdentifier = "composer.textInput"
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        consumeFocusRequestIfNeeded(for: textView, coordinator: context.coordinator)
        // 初始属性配置可能触发 TextKit 内部回调；最后再接入 delegate，避免把创建阶段
        // 误判成用户输入并反向发布 SwiftUI Binding。
        textView.delegate = context.coordinator
        return textView
    }

    func updateUIView(_ uiView: CommandSubmitTextView, context: Context) {
        let coordinator = context.coordinator
        // updateUIView 本身运行在 SwiftUI 的视图更新事务中。整段同步都标记为系统驱动，
        // 即使某个 UIKit setter 同步触发 delegate，也不能在同一事务里反向修改 Binding。
        coordinator.performSwiftUISynchronization {
            coordinator.parent = self
            uiView.onRetireFromComposer = { [weak coordinator] in
                coordinator?.retireFromComposer()
            }
            submitBridge.attach(uiView)
            uiView.onCommandSubmit = onSubmit
            uiView.onContentLayoutChanged = { textView in
                coordinator.reportContentHeight(for: textView)
            }
            uiView.onVoiceShortcutPressChanged = onVoiceShortcutPressChanged
            uiView.isSkillAutocompleteActive = skillAutocompleteActive
            uiView.onSkillAutocompleteMove = onSkillAutocompleteMove
            uiView.onSkillAutocompleteCommit = onSkillAutocompleteCommit
            uiView.onSkillAutocompleteDismiss = onSkillAutocompleteDismiss
            consumeFocusRequestIfNeeded(for: uiView, coordinator: coordinator)
            coordinator.updateCompositionState(uiView.hasMarkedText)
            let shouldForceExternalTextSync = coordinator.lastAppliedExternalRevision != externalTextRevision

            // 字体/颜色只在真正变化时赋值：UITextView 的 font setter 会让 TextKit 对整段文本重新排版，
            // 打字时（尤其是中文 marked text 合成期间）每次按键都重设会打断输入法合成并造成可感知卡顿。
            var needsContentHeightReport = false
            if uiView.font != font {
                uiView.font = font
                needsContentHeightReport = true
            }
            if uiView.textColor != textColor {
                uiView.textColor = textColor
            }
            if uiView.tintColor != tintColor {
                uiView.tintColor = tintColor
            }
            if uiView.textContainerInset != textContainerInset {
                uiView.textContainerInset = textContainerInset
                needsContentHeightReport = true
            }

            if uiView.hasMarkedText, coordinator.lastSyncedText == text, !shouldForceExternalTextSync {
                // 中文/日文等输入法会先把拼音或假名放在 marked text 中。此时外层草稿仍是
                // 上一次已确认文本，不能把 SwiftUI 状态回灌到 UITextView，否则首个字母会被提交成正文。
                if needsContentHeightReport {
                    coordinator.reportContentHeight(for: uiView)
                }
                return
            }

            guard coordinator.lastSyncedText != text || shouldForceExternalTextSync else {
                if needsContentHeightReport {
                    coordinator.reportContentHeight(for: uiView)
                }
                return
            }

            // 外部清空/恢复草稿时才同步 UIKit 文本；用户正常输入由 delegate 单向写回，
            // 避免中文 marked text 和光标位置在 SwiftUI 重算时被反复重置。
            let previousText = uiView.text ?? ""
            let selectedRange = uiView.selectedRange
            uiView.text = text
            coordinator.lastSyncedText = text
            coordinator.lastAppliedExternalRevision = externalTextRevision
            coordinator.updateCompositionState(false)
            uiView.selectedRange = TextSelectionPolicy.rangeAfterExternalTextSync(
                previousText: previousText,
                nextText: text,
                previousRange: selectedRange
            )
            coordinator.reportContentHeight(for: uiView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func consumeFocusRequestIfNeeded(
        for textView: CommandSubmitTextView,
        coordinator: Coordinator
    ) {
        guard let requestID = ComposerFocusRequestPolicy.requestToConsume(
            pending: focusRequestID,
            lastHandled: coordinator.lastHandledFocusRequestID
        ) else {
            return
        }
        coordinator.lastHandledFocusRequestID = requestID
        let requestBinding = _focusRequestID
        DispatchQueue.main.async { [weak textView] in
            textView?.becomeFirstResponder()
            // token 属于父 View，是跨 UIView 重建的一次性事实；消费后立即清空。
            // 即使当前 UITextView 已在转场中销毁，也不能把旧请求留给下一个实例。
            requestBinding.wrappedValue = ComposerFocusRequestPolicy.pendingRequest(
                afterConsuming: requestID,
                current: requestBinding.wrappedValue
            )
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        var lastSyncedText = ""
        var lastAppliedExternalRevision = 0
        var lastHandledFocusRequestID: UUID?
        private(set) var isSynchronizingFromSwiftUI = false
        private var lastReportedContentHeight: CGFloat = 0
        private var pendingContentHeight: CGFloat?
        private var isContentHeightReportScheduled = false
        private var isComposingText = false
        private var pendingCompositionState: Bool?
        private var isCompositionStateReportScheduled = false
        private var lastSkillQuery: ComposerSkillQuery?
        private var pendingSkillQuery: ComposerSkillQuery?
        private var isSkillQueryReportScheduled = false
        private var isRetiredFromComposer = false

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func performSwiftUISynchronization(_ updates: () -> Void) {
            let wasAlreadySynchronizing = isSynchronizingFromSwiftUI
            isSynchronizingFromSwiftUI = true
            defer {
                // 保留外层保护状态，让未来嵌套同步也不会提前开放 delegate 回写。
                isSynchronizingFromSwiftUI = wasAlreadySynchronizing
            }
            updates()
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isRetiredFromComposer,
                  !isSynchronizingFromSwiftUI,
                  (textView as? CommandSubmitTextView)?.isRetiredFromComposer != true
            else {
                return
            }
            let currentText = textView.text ?? ""
            let hasMarkedText = textView.hasMarkedText
            updateCompositionState(hasMarkedText)
            if !hasMarkedText {
                syncCommittedTextIfNeeded(currentText, force: false)
            }
            updateSkillQuery(for: textView)
            reportContentHeight(for: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isRetiredFromComposer,
                  !isSynchronizingFromSwiftUI,
                  (textView as? CommandSubmitTextView)?.isRetiredFromComposer != true
            else {
                return
            }
            let hasMarkedText = textView.hasMarkedText
            updateCompositionState(hasMarkedText)
            if !hasMarkedText {
                // 部分输入法结束 marked text 时只触发 selection 变化；这里补一次收敛。
                syncCommittedTextIfNeeded(textView.text ?? "", force: false)
            }
            updateSkillQuery(for: textView)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            guard !isRetiredFromComposer,
                  !isSynchronizingFromSwiftUI,
                  (textView as? CommandSubmitTextView)?.isRetiredFromComposer != true
            else {
                return
            }
            updateCompositionState(false)
            // 失焦是最后兜底边界，保证 UIKit 文本不会滞留在旧 draft 之外。
            syncCommittedTextIfNeeded(textView.text ?? "", force: true)
            publishSkillQuery(nil)
        }

        func updateCompositionState(_ isComposing: Bool) {
            guard !isRetiredFromComposer else {
                return
            }
            guard isComposingText != isComposing else {
                return
            }
            isComposingText = isComposing
            pendingCompositionState = isComposing
            guard !isCompositionStateReportScheduled else {
                return
            }
            isCompositionStateReportScheduled = true
            // updateUIView 也会检查 marked text；状态回写放到下一拍，避免在 SwiftUI 更新周期内直接改 @State。
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                self.isCompositionStateReportScheduled = false
                guard !self.isRetiredFromComposer else {
                    return
                }
                guard let isComposing = self.pendingCompositionState else {
                    return
                }
                self.pendingCompositionState = nil
                self.parent.onCompositionStateChange(isComposing)
            }
        }

        func reportContentHeight(for textView: UITextView) {
            guard !isRetiredFromComposer,
                  (textView as? CommandSubmitTextView)?.isRetiredFromComposer != true
            else {
                return
            }
            let height = visibleContentHeight(for: textView)
            guard abs(lastReportedContentHeight - height) > 0.5 else {
                return
            }
            pendingContentHeight = height
            guard !isContentHeightReportScheduled else {
                return
            }
            isContentHeightReportScheduled = true
            // UIKit 布局回调可能发生在 SwiftUI 更新周期里，异步并合并回写可避免
            // 长语音草稿编辑时 size/状态更新形成一串主线程抖动。
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                self.isContentHeightReportScheduled = false
                guard !self.isRetiredFromComposer else {
                    return
                }
                guard let height = self.pendingContentHeight else {
                    return
                }
                self.pendingContentHeight = nil
                guard abs(self.lastReportedContentHeight - height) > 0.5 else {
                    return
                }
                self.lastReportedContentHeight = height
                self.parent.onContentHeightChange(height)
            }
        }

        private func syncCommittedTextIfNeeded(_ currentText: String, force: Bool) {
            guard force || currentText != lastSyncedText || currentText != parent.text else {
                return
            }
            lastSyncedText = currentText
            if parent.text != currentText {
                parent.text = currentText
            }
        }

        private func updateSkillQuery(for textView: UITextView) {
            let query = textView.hasMarkedText
                ? nil
                : ComposerSkillQuery.match(text: textView.text ?? "", selectedRange: textView.selectedRange)
            publishSkillQuery(query)
        }

        private func publishSkillQuery(_ query: ComposerSkillQuery?) {
            guard !isRetiredFromComposer else { return }
            guard query != lastSkillQuery else { return }
            lastSkillQuery = query
            pendingSkillQuery = query
            guard !isSkillQueryReportScheduled else { return }
            isSkillQueryReportScheduled = true
            // 光标和正文经常在同一个输入事件里连续变化；只把这一拍的最终查询交给 SwiftUI。
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isRetiredFromComposer else {
                    return
                }
                self.isSkillQueryReportScheduled = false
                let latestQuery = self.pendingSkillQuery
                self.pendingSkillQuery = nil
                self.parent.onSkillQueryChange(latestQuery)
            }
        }

        func retireFromComposer() {
            isRetiredFromComposer = true
            pendingContentHeight = nil
            pendingCompositionState = nil
            lastSkillQuery = nil
            pendingSkillQuery = nil
        }

        private func visibleContentHeight(for textView: UITextView) -> CGFloat {
            let contentHeight = ceil(textView.contentSize.height)
            if contentHeight > 0 {
                return clampedVisibleHeight(contentHeight)
            }
            let width = max(textView.bounds.width, 1)
            let fittingSize = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            return clampedVisibleHeight(ceil(textView.sizeThatFits(fittingSize).height))
        }

        private func clampedVisibleHeight(_ height: CGFloat) -> CGFloat {
            min(max(height, parent.minHeight), parent.maxHeight)
        }
    }
}

extension UITextView {
    var hasMarkedText: Bool {
        markedTextRange != nil
    }
}

final class CommandSubmitTextView: UITextView {
    var onCommandSubmit: (() -> Bool)?
    var onContentLayoutChanged: ((CommandSubmitTextView) -> Void)?
    var onVoiceShortcutPressChanged: ((Bool) -> Void)?
    var onSkillAutocompleteMove: ((Int) -> Void)?
    var onSkillAutocompleteCommit: (() -> Void)?
    var onSkillAutocompleteDismiss: (() -> Void)?
    var onRetireFromComposer: (() -> Void)?
    var isSkillAutocompleteActive = false
    private(set) var isRetiredFromComposer = false
    private var isVoiceShortcutPressed = false
    private var lastReportedLayoutWidth: CGFloat = 0

    func retireFromComposer() {
        guard !isRetiredFromComposer else { return }
        isRetiredFromComposer = true
        onRetireFromComposer?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard abs(bounds.width - lastReportedLayoutWidth) > 0.5 else {
            return
        }
        lastReportedLayoutWidth = bounds.width
        onContentLayoutChanged?(self)
    }

    override var keyCommands: [UIKeyCommand]? {
        let submit = UIKeyCommand(
            title: L10n.text("ui.send"),
            action: #selector(handleCommandReturn),
            input: "\r",
            modifierFlags: .command,
            discoverabilityTitle: L10n.text("ui.send")
        )
        return (super.keyCommands ?? []) + [
            submit,
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(selectPreviousSkill)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(selectNextSkill)),
            UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(commitSkillAutocomplete)),
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(commitSkillAutocomplete)),
            UIKeyCommand(input: "\u{1B}", modifierFlags: [], action: #selector(dismissSkillAutocomplete))
        ]
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(selectPreviousSkill),
             #selector(selectNextSkill),
             #selector(commitSkillAutocomplete),
             #selector(dismissSkillAutocomplete):
            return isSkillAutocompleteActive
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if containsVoiceShortcutPress(presses) {
            guard !isVoiceShortcutPressed else {
                return
            }
            isVoiceShortcutPressed = true
            onVoiceShortcutPressChanged?(true)
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if containsVoiceShortcutPress(presses) {
            finishVoiceShortcutPress()
            return
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if containsVoiceShortcutPress(presses) {
            finishVoiceShortcutPress()
            return
        }
        super.pressesCancelled(presses, with: event)
    }

    @objc private func handleCommandReturn() {
        // 普通回车仍由 UITextView 插入换行；只有 Command + Return 走发送。
        _ = onCommandSubmit?()
    }

    @objc private func selectPreviousSkill() {
        onSkillAutocompleteMove?(-1)
    }

    @objc private func selectNextSkill() {
        onSkillAutocompleteMove?(1)
    }

    @objc private func commitSkillAutocomplete() {
        onSkillAutocompleteCommit?()
    }

    @objc private func dismissSkillAutocomplete() {
        onSkillAutocompleteDismiss?()
    }

    private func finishVoiceShortcutPress() {
        guard isVoiceShortcutPressed else {
            return
        }
        isVoiceShortcutPressed = false
        onVoiceShortcutPressChanged?(false)
    }

    private func containsVoiceShortcutPress(_ presses: Set<UIPress>) -> Bool {
        presses.contains { press in
            Self.isVoiceShortcutKey(press.key)
        }
    }

    private static func isVoiceShortcutKey(_ key: UIKey?) -> Bool {
        guard let key else {
            return false
        }
        switch key.keyCode {
        case .keyboardLANG1, .keyboardLANG2, .keyboardLANG3, .keyboardLANG4, .keyboardLANG5,
             .keyboardLANG6, .keyboardLANG7, .keyboardLANG8, .keyboardLANG9:
            // UIKit 没有公开 Fn/Globe 的专用 keyCode；部分硬件键盘会把输入法切换键上报为 LANG1...LANG9。
            return key.charactersIgnoringModifiers.isEmpty
        default:
            return false
        }
    }
}

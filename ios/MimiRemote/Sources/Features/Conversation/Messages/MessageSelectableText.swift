import SwiftUI
import UIKit

struct MessageTextActions {
    var copyText: String
    var retry: (() -> Void)?
    var stop: (() -> Void)?
}

private struct MessageTextActionsKey: EnvironmentKey {
    static let defaultValue: MessageTextActions? = nil
}

extension EnvironmentValues {
    var messageTextActions: MessageTextActions? {
        get { self[MessageTextActionsKey.self] }
        set { self[MessageTextActionsKey.self] = newValue }
    }
}

struct MessageSelectableText: UIViewRepresentable {
    @Environment(\.messageTextActions) private var actions
    @Environment(\.openURL) private var openURL
    let document: MessageTextDocument
    let style: MessageTextStyle
    var fillsWidth = true

    func makeUIView(context: Context) -> MessageTextView {
        MessageTextView()
    }

    func updateUIView(_ textView: MessageTextView, context: Context) {
        textView.messageActions = actions
        textView.openLink = { openURL($0) }
        textView.apply(document, style: style)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MessageTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return uiView.measuredSize(width: width, fillsWidth: fillsWidth)
    }
}

enum MessageTextSelectionPolicy {
    static func preservedRange(_ range: NSRange, previous: String, updated: String) -> NSRange? {
        let previousText = previous as NSString
        let updatedText = updated as NSString
        let end = NSMaxRange(range)
        guard range.location != NSNotFound, range.length > 0,
              end <= previousText.length, end <= updatedText.length,
              previousText.substring(to: end) == updatedText.substring(to: end) else { return nil }
        return range
    }

    static func copyText(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{fffc}\n", with: "")
            .replacingOccurrences(of: "\u{fffc}", with: "")
    }
}

final class MessageTextView: UITextView, UITextViewDelegate, UIEditMenuInteractionDelegate, UIGestureRecognizerDelegate {
    var messageActions: MessageTextActions?
    var openLink: ((URL) -> Void)?
    private(set) var isSelectingMessageText = false
    private var pendingSelection = false
    private var pressLocation = CGPoint.zero
    private var document = MessageTextDocument(text: NSAttributedString(string: ""), codeBlocks: [])
    private var messageStyle: MessageTextStyle?
    private var codeBackgrounds: [UIView] = []
    private var codeLabels: [UILabel] = []
    private var codeCopyButtons: [UIButton] = []
    private lazy var messageMenu = UIEditMenuInteraction(delegate: self)
    private lazy var messagePress = UILongPressGestureRecognizer(target: self, action: #selector(showMessageMenu(_:)))
    private lazy var linkTap = UITapGestureRecognizer(target: self, action: #selector(openTappedLink(_:)))
    private lazy var outsideTap = UITapGestureRecognizer(target: self, action: #selector(dismissSelection))

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: .zero)
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        backgroundColor = .clear
        isEditable = false
        isSelectable = false
        isScrollEnabled = false
        contentInsetAdjustmentBehavior = .never
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        delegate = self
        addInteraction(messageMenu)
        addGestureRecognizer(messagePress)
        addGestureRecognizer(linkTap)
        linkTap.require(toFail: messagePress)
        outsideTap.cancelsTouchesInView = false
        outsideTap.delegate = self
        accessibilityIdentifier = "conversation.message.text"
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: L10n.text("ui.copy")) { [weak self] _ in
                self?.copyMessage()
                return true
            },
            UIAccessibilityCustomAction(name: L10n.text("ui.select_text")) { [weak self] _ in
                self?.beginSelection()
                return true
            }
        ]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ updated: MessageTextDocument, style: MessageTextStyle) {
        messageStyle = style
        tintColor = style.linkColor
        linkTextAttributes = [.foregroundColor: style.linkColor]
        if style.markdown.underlinesLinks { linkTextAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        let preserved = isSelectingMessageText
            ? MessageTextSelectionPolicy.preservedRange(selectedRange, previous: document.text.string, updated: updated.text.string)
            : nil
        let changed = !textStorage.isEqual(to: updated.text)
        document = updated
        if changed {
            // 流式追加继续使用同一个 TextKit 文档；已有选区只在其前面的文字未变时保留。
            if isSelectingMessageText && preserved == nil { dismissSelection() }
            attributedText = updated.text
            if let preserved { selectedRange = preserved }
            invalidateIntrinsicContentSize()
        }
        updateCodeControls()
        setNeedsLayout()
    }

    func measuredSize(width: CGFloat, fillsWidth: Bool) -> CGSize {
        textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return CGSize(width: fillsWidth ? width : max(1, min(width, ceil(used.maxX))), height: max(1, ceil(used.maxY) + (document.codeBlocks.last?.range.upperBound == textStorage.length ? 10 : 0)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutCodeControls()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { endSelection() }
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { endSelection() }
        return resigned
    }

    override func copy(_ sender: Any?) {
        guard selectedRange.length > 0, NSMaxRange(selectedRange) <= textStorage.length else { return }
        UIPasteboard.general.string = MessageTextSelectionPolicy.copyText((textStorage.string as NSString).substring(with: selectedRange))
    }

    @objc private func showMessageMenu(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, textStorage.length > 0 else { return }
        window?.endEditing(true)
        pressLocation = gesture.location(in: self)
        messageMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: pressLocation))
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        if isSelectingMessageText {
            return UIMenu(children: suggestedActions.isEmpty ? [UIAction(title: L10n.text("ui.copy")) { [weak self] _ in self?.copy(nil) }] : suggestedActions)
        }
        var items: [UIMenuElement] = [
            UIAction(title: L10n.text("ui.copy"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copyMessage() },
            UIAction(title: L10n.text("ui.select_text"), image: UIImage(systemName: "text.cursor")) { [weak self] _ in self?.pendingSelection = true }
        ]
        if let retry = messageActions?.retry {
            items.append(UIAction(title: L10n.text("ui.try_again"), image: UIImage(systemName: "arrow.clockwise")) { _ in retry() })
        }
        if let stop = messageActions?.stop {
            items.append(UIAction(title: L10n.text("ui.stop"), image: UIImage(systemName: "stop.circle"), attributes: .destructive) { _ in stop() })
        }
        return UIMenu(children: items)
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration, animator: any UIEditMenuInteractionAnimating) {
        animator.addCompletion { [weak self] in
            guard let self, self.pendingSelection else { return }
            self.pendingSelection = false
            self.beginSelection()
        }
    }

    func beginSelection() {
        guard textStorage.length > 0 else { return }
        // 只切换原生手势与选区，正文、字号、布局和视图身份始终不变。
        isSelectingMessageText = true
        isSelectable = true
        messagePress.isEnabled = false
        linkTap.isEnabled = false
        becomeFirstResponder()
        selectedRange = wordRange(at: pressLocation)
        var ancestor = superview
        while let view = ancestor {
            if view is UIScrollView {
                view.addGestureRecognizer(outsideTap)
                break
            }
            ancestor = view.superview
        }
        messageMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: pressLocation))
    }

    @objc private func dismissSelection() {
        resignFirstResponder()
        endSelection()
    }

    private func endSelection() {
        guard isSelectingMessageText else { return }
        isSelectingMessageText = false
        pendingSelection = false
        selectedRange = NSRange(location: 0, length: 0)
        isSelectable = false
        messagePress.isEnabled = true
        linkTap.isEnabled = true
        outsideTap.view?.removeGestureRecognizer(outsideTap)
        messageMenu.dismissMenu()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === outsideTap else { return true }
        return touch.view?.isDescendant(of: self) != true
    }

    private func wordRange(at point: CGPoint) -> NSRange {
        let source = textStorage.string as NSString
        let index = min(layoutManager.characterIndex(for: point, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil), source.length - 1)
        var result = source.rangeOfComposedCharacterSequence(at: index)
        var nearestDistance = Int.max
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: [.byWords, .substringNotRequired]) { _, range, _, stop in
            let distance = max(range.location - index, index - NSMaxRange(range) + 1, 0)
            if distance < nearestDistance {
                result = range
                nearestDistance = distance
            }
            if distance == 0 || range.location > index { stop.pointee = true }
        }
        return result
    }

    private func copyMessage() {
        UIPasteboard.general.string = messageActions?.copyText ?? MessageTextSelectionPolicy.copyText(textStorage.string)
    }

    @objc private func openTappedLink(_ gesture: UITapGestureRecognizer) {
        guard textStorage.length > 0 else { return }
        let point = gesture.location(in: self)
        let index = layoutManager.characterIndex(for: point, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        guard index < textStorage.length,
              let url = textStorage.attribute(.link, at: index, effectiveRange: nil) as? URL else { return }
        let glyph = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        guard layoutManager.boundingRect(forGlyphRange: glyph, in: textContainer).insetBy(dx: -3, dy: -3).contains(point) else { return }
        openLink?(url)
    }

    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        openLink?(URL)
        return false
    }

    private func updateCodeControls() {
        while codeBackgrounds.count > document.codeBlocks.count {
            codeBackgrounds.removeLast().removeFromSuperview()
            codeLabels.removeLast().removeFromSuperview()
            codeCopyButtons.removeLast().removeFromSuperview()
        }
        while codeBackgrounds.count < document.codeBlocks.count {
            let background = UIView()
            background.isUserInteractionEnabled = false
            background.layer.cornerRadius = 8
            insertSubview(background, at: 0)
            codeBackgrounds.append(background)
            let label = UILabel()
            addSubview(label)
            codeLabels.append(label)
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: "doc.on.doc"), for: .normal)
            button.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 14), forImageIn: .normal)
            button.accessibilityLabel = L10n.text("ui.copy_code")
            button.addTarget(self, action: #selector(copyCode(_:)), for: .touchUpInside)
            addSubview(button)
            codeCopyButtons.append(button)
        }
        guard let style = messageStyle else { return }
        for (index, block) in document.codeBlocks.enumerated() {
            codeBackgrounds[index].backgroundColor = UIColor(style.markdown.codeBackground)
            codeLabels[index].text = block.language
            codeLabels[index].font = style.font(size: 13)
            codeLabels[index].textColor = UIColor(style.markdown.codeForeground).withAlphaComponent(0.75)
            codeCopyButtons[index].tintColor = UIColor(style.markdown.codeForeground).withAlphaComponent(0.75)
        }
    }

    private func layoutCodeControls() {
        for (index, block) in document.codeBlocks.enumerated() {
            let glyphs = layoutManager.glyphRange(forCharacterRange: block.range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            codeBackgrounds[index].frame = CGRect(x: 0, y: rect.minY, width: bounds.width, height: rect.height + 10)
            codeLabels[index].frame = CGRect(x: 10, y: rect.minY, width: max(0, bounds.width - 64), height: 38)
            codeCopyButtons[index].frame = CGRect(x: max(0, bounds.width - 44), y: rect.minY, width: 44, height: 44)
        }
    }

    @objc private func copyCode(_ sender: UIButton) {
        guard let index = codeCopyButtons.firstIndex(of: sender), document.codeBlocks.indices.contains(index) else { return }
        UIPasteboard.general.string = document.codeBlocks[index].text
    }
}

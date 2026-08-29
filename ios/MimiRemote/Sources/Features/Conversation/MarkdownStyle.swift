import SwiftUI

struct MarkdownStyle: Equatable {
    let role: ConversationMessage.Role
    let textColor: Color
    let secondaryColor: Color
    let linkColor: Color
    let codeForeground: Color
    let codeBackground: Color
    let tableBackground: Color
    let planCardBackground: Color
    let planCardBorder: Color
    let quoteBar: Color
    let dividerColor: Color
    let blockSpacing: CGFloat
    let textLineSpacing: CGFloat
    let fontScale: Double

    static func make(
        role: ConversationMessage.Role,
        colorScheme: ColorScheme,
        fontScale: Double = 1.0,
        tokens: ThemeTokens? = nil
    ) -> MarkdownStyle {
        let isUser = role == .user
        let fallbackAccent = colorScheme == .dark
            ? Color(red: 0.77, green: 0.56, blue: 0.84)
            : Color(red: 0.38, green: 0.12, blue: 0.41)
        let textColor = isUser
            ? (tokens?.userBubbleForeground ?? .primary)
            : (tokens?.conversationPrimaryText ?? .primary)
        return MarkdownStyle(
            role: role,
            textColor: textColor,
            secondaryColor: isUser ? textColor.opacity(0.68) : (tokens?.conversationSecondaryText ?? .secondary),
            linkColor: tokens?.accent ?? fallbackAccent,
            codeForeground: tokens?.codeText ?? .primary,
            codeBackground: tokens?.codeBlock ?? Color(.tertiarySystemBackground),
            tableBackground: tokens?.elevatedSurface ?? Color(.secondarySystemBackground),
            planCardBackground: tokens?.planCardBackground ?? tokens?.elevatedSurface ?? Color(.secondarySystemBackground),
            planCardBorder: tokens?.planCardBorder ?? tokens?.border ?? Color(.separator),
            quoteBar: tokens?.accent.opacity(colorScheme == .dark ? 0.76 : 0.64)
                ?? fallbackAccent.opacity(colorScheme == .dark ? 0.76 : 0.64),
            dividerColor: tokens?.border ?? Color(.separator),
            // 回复以长文档方式阅读，字号和行距略放大；用户仍可用全局字号倍率继续调节。
            //
            // 17pt / 22pt 行高是 iOS 正文阅读的标准档（.body），也是同类长文客户端
            // 的落点。之前的 16pt + 4pt 行距在中文长段落里同时偏小且偏挤，
            // 与手机上并排对比时最先被读成"糙"。段间距同步放大，保证段落边界
            // 仍然比行间距明显一档。
            blockSpacing: 12,
            textLineSpacing: 5,
            fontScale: fontScale
        )
    }

    var bodyFont: Font {
        .system(size: scaled(17))
    }

    var codeFont: Font {
        // 行内代码与代码块统一使用 15pt，避免代码在正文排版中显得过小。
        .system(size: scaled(15), design: .monospaced)
    }

    var captionFont: Font {
        .system(size: scaled(13), weight: .medium)
    }

    func headingFont(level: Int) -> Font {
        switch level {
        // 标题与 17pt 正文保持可辨识的层级差：正文上浮一档后，原来的 16pt h5
        // 会和正文同号，标题就只剩字重可用。整条梯度同步上移一档。
        case 1:
            return .system(size: scaled(24), weight: .bold)
        case 2:
            return .system(size: scaled(21), weight: .bold)
        case 3:
            return .system(size: scaled(19), weight: .semibold)
        case 4:
            return .system(size: scaled(18), weight: .semibold)
        default:
            return .system(size: scaled(17), weight: .semibold)
        }
    }

    func scaled(_ baseSize: CGFloat) -> CGFloat {
        baseSize * CGFloat(fontScale)
    }
}

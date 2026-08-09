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
            : (tokens?.primaryText ?? .primary)
        return MarkdownStyle(
            role: role,
            textColor: textColor,
            secondaryColor: isUser ? textColor.opacity(0.68) : (tokens?.secondaryText ?? .secondary),
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
            blockSpacing: 10,
            textLineSpacing: 4,
            fontScale: fontScale
        )
    }

    var bodyFont: Font {
        .system(size: scaled(16))
    }

    var codeFont: Font {
        // 行内代码与代码块统一使用 15pt，避免代码在正文排版中显得过小。
        .system(size: scaled(15), design: .monospaced)
    }

    var captionFont: Font {
        .system(size: scaled(12), weight: .medium)
    }

    func headingFont(level: Int) -> Font {
        switch level {
        case 1:
            return .system(size: scaled(22), weight: .bold)
        case 2:
            return .system(size: scaled(20), weight: .bold)
        case 3:
            return .system(size: scaled(18), weight: .semibold)
        case 4:
            return .system(size: scaled(17), weight: .semibold)
        default:
            return .system(size: scaled(16), weight: .semibold)
        }
    }

    func scaled(_ baseSize: CGFloat) -> CGFloat {
        baseSize * CGFloat(fontScale)
    }
}

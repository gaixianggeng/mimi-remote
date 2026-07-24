import AppKit
import SwiftUI

extension Color {
    /// 与 iOS 端默认主操作色 #4A144A 同一配色体系；深色模式提高明度，保持状态图标可读。
    static let mimiPrimary = Color(
        nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(
                    red: 196.0 / 255.0,
                    green: 143.0 / 255.0,
                    blue: 214.0 / 255.0,
                    alpha: 1
                )
            }
            return NSColor(
                red: 74.0 / 255.0,
                green: 20.0 / 255.0,
                blue: 74.0 / 255.0,
                alpha: 1
            )
        }
    )

    /// 菜单里的停止操作仍保留危险语义，但比系统红更沉稳，避免抢过主要状态和操作。
    static let mimiMutedDestructive = Color(
        nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(
                    red: 206.0 / 255.0,
                    green: 82.0 / 255.0,
                    blue: 89.0 / 255.0,
                    alpha: 1
                )
            }
            return NSColor(
                red: 164.0 / 255.0,
                green: 50.0 / 255.0,
                blue: 58.0 / 255.0,
                alpha: 1
            )
        }
    )
}

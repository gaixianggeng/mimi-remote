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

    /// 菜单栏开关使用更低饱和的品牌紫，避免系统蓝在毛玻璃背景上抢夺注意力。
    static let mimiControlAccent = Color(
        nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(
                    red: 181.0 / 255.0,
                    green: 139.0 / 255.0,
                    blue: 190.0 / 255.0,
                    alpha: 1
                )
            }
            return NSColor(
                red: 111.0 / 255.0,
                green: 76.0 / 255.0,
                blue: 115.0 / 255.0,
                alpha: 1
            )
        }
    )

    /// 健康状态只通过小圆点传达，降低饱和度后仍与警告色和错误色明确区分。
    static let mimiSuccess = Color(
        nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(
                    red: 127.0 / 255.0,
                    green: 168.0 / 255.0,
                    blue: 140.0 / 255.0,
                    alpha: 1
                )
            }
            return NSColor(
                red: 92.0 / 255.0,
                green: 143.0 / 255.0,
                blue: 112.0 / 255.0,
                alpha: 1
            )
        }
    )

    /// 更新链接保留可点击语义，同时比系统蓝更安静。
    static let mimiMutedLink = Color(
        nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(
                    red: 140.0 / 255.0,
                    green: 168.0 / 255.0,
                    blue: 192.0 / 255.0,
                    alpha: 1
                )
            }
            return NSColor(
                red: 79.0 / 255.0,
                green: 113.0 / 255.0,
                blue: 145.0 / 255.0,
                alpha: 1
            )
        }
    )
}

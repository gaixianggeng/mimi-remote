import Foundation

/// 面向用户和 App Review 的公开链接统一放在这里，避免设置页、测试和商店材料各自漂移。
/// 链接只指向公开仓库中的稳定文档，不携带设备、连接地址或任何用户标识。
enum AppExternalLinks {
    static let marketing = makeURL("https://github.com/gaixianggeng/mimi-remote")
    /// 普通用户从公开 Release 页面了解版本；系统分享则发送稳定的 latest DMG 直链。
    static let macRelease = makeURL("https://github.com/gaixianggeng/mimi-remote/releases/latest")
    static let macInstaller = makeURL("https://github.com/gaixianggeng/mimi-remote/releases/latest/download/Mimi-Remote-Mac.dmg")
    /// Windows 安装器带版本号，latest Release 页面是稳定且不会指向过期产物的入口。
    static let windowsRelease = makeURL("https://github.com/gaixianggeng/mimi-remote/releases/latest")
    static let privacyPolicy = makeURL("https://github.com/gaixianggeng/mimi-remote/blob/main/docs/privacy-policy.md")
    static let termsOfUse = makeURL("https://github.com/gaixianggeng/mimi-remote/blob/main/docs/terms-of-use.md")
    static let support = makeURL("https://github.com/gaixianggeng/mimi-remote/blob/main/docs/support.md")
    /// 首次连接引导的前置条件：电脑上要先有能用的 Codex。与 README「Get started」第一步同一链接。
    static let codexSetup = makeURL("https://learn.chatgpt.com/docs/codex/cli")
    /// Mac Catalyst 没有系统的订阅管理表单，改为打开 App Store 账户里的订阅页。
    static let manageSubscriptions = makeURL("https://apps.apple.com/account/subscriptions")

    private static func makeURL(_ value: String) -> URL {
        guard let url = URL(string: value), url.scheme == "https" else {
            preconditionFailure("Invalid public HTTPS URL: \(value)")
        }
        return url
    }
}

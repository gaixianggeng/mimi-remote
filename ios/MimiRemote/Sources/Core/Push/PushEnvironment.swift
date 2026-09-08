import Foundation

/// APNs 的 sandbox 与 production 使用两套互不相通的 Device Token。选错环境不会
/// 报错，只会让每一条推送都静默失败——这是最难查的一类问题，所以宁可多花几十行
/// 读一次描述文件，也不靠构建配置猜。
enum PushEnvironment: String, Equatable, Sendable {
    case sandbox
    case production

    /// 以嵌入的描述文件里的 `aps-environment` 为准。读不到时（App Store 构建本身
    /// 不带描述文件，模拟器也没有）退回按构建配置判断。
    static func current(
        provisioningProfile: Data? = embeddedProvisioningProfile(),
        isDebugBuild: Bool = defaultIsDebugBuild
    ) -> PushEnvironment {
        if let profile = provisioningProfile,
           let declared = apsEnvironment(inProvisioningProfile: profile) {
            return declared
        }
        return isDebugBuild ? .sandbox : .production
    }

    static var defaultIsDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static func embeddedProvisioningProfile() -> Data? {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") else {
            return nil
        }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// 描述文件是 CMS 签名信封，内嵌一段 plist。这里只做定位与解析，不校验签名：
    /// 它是本 App 自己的资源，用途仅是读出 Apple 已经写死的环境标记。
    static func apsEnvironment(inProvisioningProfile profile: Data) -> PushEnvironment? {
        guard let plist = embeddedPlist(in: profile),
              let root = try? PropertyListSerialization.propertyList(from: plist, format: nil),
              let dictionary = root as? [String: Any],
              let entitlements = dictionary["Entitlements"] as? [String: Any],
              let value = entitlements["aps-environment"] as? String
        else {
            return nil
        }
        // 描述文件用的是 Apple 的措辞（development / production），不是 APNs 主机的
        // 措辞（sandbox / production）。直接按 rawValue 解析会让 development 落空，
        // 于是 Release 构建配开发描述文件时会误用 production，推送静默失效。
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "development":
            return .sandbox
        case "production":
            return .production
        default:
            return nil
        }
    }

    private static func embeddedPlist(in profile: Data) -> Data? {
        guard let start = profile.range(of: Data("<?xml".utf8)) else { return nil }
        guard let end = profile.range(
            of: Data("</plist>".utf8),
            options: [],
            in: start.lowerBound..<profile.endIndex
        ) else {
            return nil
        }
        return profile.subdata(in: start.lowerBound..<end.upperBound)
    }
}

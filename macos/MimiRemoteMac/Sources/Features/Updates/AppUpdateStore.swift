import Foundation
import Observation

/// 正式安装包只使用 X.Y.Z；按数值比较，避免把 0.3.9 排在 0.3.13 后面。
struct AppReleaseVersion: Comparable {
    let components: [Int]

    init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } })
        else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        components = numbers
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

struct MacAppRelease: Equatable {
    let version: String
    let downloadURL: URL
    let releaseURL: URL

    static func decode(_ data: Data) throws -> Self {
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !release.draft, !release.prerelease,
              release.tag_name.hasPrefix("v"),
              AppReleaseVersion(String(release.tag_name.dropFirst())) != nil
        else { throw AppUpdateError.invalidRelease }
        let base = "https://github.com/gaixianggeng/mimi-remote/releases"
        let download = "\(base)/download/\(release.tag_name)/Mimi-Remote-Mac.dmg"
        // 同一 Release 也含 Windows/Linux 产物。只有正式 Mac DMG 上传完成才提供更新。
        // 固定仓库及版本路径，避免把响应中的任意链接交给系统打开。
        guard release.assets.contains(where: {
            $0.name == "Mimi-Remote-Mac.dmg" && $0.state == "uploaded"
                && $0.browser_download_url == download
        }) else { throw AppUpdateError.invalidRelease }
        return Self(
            version: String(release.tag_name.dropFirst()),
            downloadURL: URL(string: download)!,
            releaseURL: URL(string: "\(base)/tag/\(release.tag_name)")!
        )
    }

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let state: String
            let browser_download_url: String
        }
    }
}

enum AppUpdateError: LocalizedError {
    case invalidRelease
    case invalidCurrentVersion
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .invalidRelease: "暂时无法获取可用的 Mac 正式安装包，请稍后重试。"
        case .invalidCurrentVersion: "无法识别当前 App 版本，请前往发布页面查看。"
        case .requestFailed: "无法连接更新服务，请检查网络后重试。"
        }
    }
}

struct AppUpdateClient {
    var latestRelease: () async throws -> MacAppRelease

    static func live(session: URLSession = .shared) -> Self {
        Self {
            let url = URL(string: "https://api.github.com/repos/gaixianggeng/mimi-remote/releases/latest")!
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw AppUpdateError.requestFailed
            }
            return try MacAppRelease.decode(data)
        }
    }
}

@MainActor
@Observable
final class AppUpdateStore {
    let currentVersion: String
    private(set) var isChecking = false
    private(set) var availableRelease: MacAppRelease?
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?
    private(set) var deferredVersion: String?
    private var lastAttempt: Date?
    private let client: AppUpdateClient
    private let defaults: UserDefaults
    private static let deferredVersionKey = "appUpdate.deferredVersion"
    static let checkInterval: TimeInterval = 24 * 60 * 60

    init(
        currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知",
        client: AppUpdateClient = .live(),
        defaults: UserDefaults = .standard
    ) {
        self.currentVersion = currentVersion
        self.client = client
        self.defaults = defaults
        deferredVersion = defaults.string(forKey: Self.deferredVersionKey)
    }

    var showsUpdateNotice: Bool {
        guard let availableRelease else { return false }
        return availableRelease.version != deferredVersion
    }

    func deferUpdate() {
        deferredVersion = availableRelease?.version
        defaults.set(deferredVersion, forKey: Self.deferredVersionKey)
    }

    func check(manual: Bool, now: Date = Date()) async {
        guard !isChecking else { return }
        if !manual, let lastAttempt, now.timeIntervalSince(lastAttempt) < Self.checkInterval {
            return
        }
        isChecking = true
        lastAttempt = now
        if manual {
            errorMessage = nil
            statusMessage = nil
        }
        defer { isChecking = false }
        do {
            guard let current = AppReleaseVersion(currentVersion) else {
                throw AppUpdateError.invalidCurrentVersion
            }
            let release = try await client.latestRelease()
            try Task.checkCancellation()
            guard let latest = AppReleaseVersion(release.version) else {
                throw AppUpdateError.invalidRelease
            }
            availableRelease = latest > current ? release : nil
            errorMessage = nil
            statusMessage = nil
            if manual, latest == current {
                statusMessage = "当前已是最新正式版（\(currentVersion)）。"
            } else if manual, latest < current {
                statusMessage = "当前版本高于最新正式版，无需更新。"
            }
        } catch is CancellationError {
            // App 退出取消检查时，不生成失败提示。
        } catch {
            if manual, !Task.isCancelled {
                errorMessage = (error as? AppUpdateError)?.errorDescription
                    ?? AppUpdateError.requestFailed.errorDescription
            }
        }
    }

    func runAutomaticChecks() async {
        // 任务由 App 持有，与菜单弹窗和后台服务状态无关；关闭菜单后仍会检查。
        // 启动时检查一次，持续运行期间每 24 小时检查；“稍后”按版本跨重启保留。
        while !Task.isCancelled {
            await check(manual: false)
            do {
                // 手动检查也会刷新时间；下一轮等待剩余间隔，避免直接再跳过一整天。
                let elapsed = lastAttempt.map { Date().timeIntervalSince($0) } ?? 0
                try await Task.sleep(for: .seconds(max(1, Self.checkInterval - elapsed)))
            } catch { return }
        }
    }
}

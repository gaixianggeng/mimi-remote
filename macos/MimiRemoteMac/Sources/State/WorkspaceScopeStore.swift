import Darwin
import Foundation
import Observation

/// 扩大代码浏览范围前的完整授权预览，让用户在确认前看清当前与拟授权的完整目录边界。
struct WorkspaceBrowseScopePreview: Equatable, Sendable {
    let currentScanRoot: URL
    let currentBrowseRoot: URL
    let proposedBrowseRoot: URL
    let widensBeyondScanRoot: Bool
    let coversHomeDirectory: Bool

    var summaryLines: [String] {
        var lines = [
            "代码目录（扫描范围）：\(currentScanRoot.path)",
            "当前手机可浏览范围：\(currentBrowseRoot.path)",
            "确认后的完整手机可浏览范围：\(proposedBrowseRoot.path)",
        ]
        if coversHomeDirectory {
            lines.append("注意：拟授权范围包含整个个人主目录及其下全部子目录。")
        } else if widensBeyondScanRoot {
            lines.append("注意：已配对手机将可浏览上述完整目录树，不再局限于代码目录本身。")
        } else {
            lines.append("拟授权范围与当前代码目录一致，保持最小权限边界。")
        }
        lines.append("取消扩权不会修改配置，也不影响任何已配对设备。")
        return lines
    }
}

struct WorkspaceScopeDependencies {
    var preflight: @Sendable () async throws -> OnboardingPreflightReport
    var updateWorkspaceScope: @MainActor (_ scanRoot: URL, _ browseRoot: URL) async throws -> Void
    var directoryExists: @Sendable (URL) -> Bool
    var homeDirectory: @Sendable () -> URL
    var verifiesSingleGrant: @Sendable (OnboardingPreflightReport) -> Bool
    var reloadIfRunning: @MainActor () async throws -> Void = {}

    @MainActor
    static func live(hostStore: HostStore) -> WorkspaceScopeDependencies {
        let agent = hostStore.agent
        let verifiedCapability = hostStore.verifiedOnboardingCapability
        return WorkspaceScopeDependencies(
            preflight: {
                try await agent.preflight(
                    OnboardingPreflightOptions(
                        stage: .pair,
                        progressJSON: false,
                        verifiedConfigured: agent.configExists(),
                        verifiedCapability: verifiedCapability
                    ),
                    nil
                )
            },
            updateWorkspaceScope: { scanRoot, browseRoot in
                try await agent.updateWorkspace(scanRoot, browseRoot)
            },
            directoryExists: { url in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            },
            homeDirectory: {
                FileManager.default.homeDirectoryForCurrentUser
            },
            verifiesSingleGrant: { report in
                let config = FileManager.default.homeDirectoryForCurrentUser
                    .appending(path: "Library/Application Support/mimi-remote/config.json")
                return report.configPath == config.path && Self.hasSingleGrant(at: config, report: report)
            },
            reloadIfRunning: {
                if hostStore.owner != .none { try await hostStore.restartServiceForOnboarding() }
            }
        )
    }

    // preflight v1 projects the first root. The BE-3 workspace command replaces both arrays.
    // Read only from the same private file to check that the preview describes every grant.
    static func hasSingleGrant(at config: URL, report: OnboardingPreflightReport) -> Bool {
        let fd = open(config.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        let limit = 4 * 1024 * 1024
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_size <= limit,
              let data = try? handle.read(upToCount: limit + 1), data.count <= limit,
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        func matches(_ key: String, _ root: String) -> Bool {
            let values = fields.filter { $0.key.lowercased() == key }
            guard values.count == 1, let roots = values.first?.value as? [String] else { return false }
            return roots == [root]
        }
        return matches("scan_roots", report.scanRoot) && matches("browse_roots", report.browseRoot)
    }
}

/// 设置页「扩大代码浏览范围（可选）」状态管理：
/// 始终先通过被动预检读取当前生效范围，展示完整授权预览，取消时零写入且不伤及已有配对。
@MainActor
@Observable
final class WorkspaceScopeStore {
    private(set) var configured = false
    private(set) var scanRoot: URL?
    private(set) var browseRoot: URL?
    private(set) var pendingPreview: WorkspaceBrowseScopePreview?
    private(set) var localNetworkStatus = "尚未确认"
    private(set) var isLoading = false
    private(set) var isApplying = false
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?

    private let deps: WorkspaceScopeDependencies

    init(dependencies: WorkspaceScopeDependencies) {
        self.deps = dependencies
    }

    var canWidenBrowseScope: Bool {
        configured && scanRoot != nil && !isApplying && !isLoading
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let report = try await deps.preflight()
            let permission = report.checks.first { $0.id == .permissionLocalNetwork }
            if permission?.code == "permission_local_network_denied" {
                localNetworkStatus = "本地网络访问已被拒绝"
            } else {
                localNetworkStatus = permission?.state == .ok ? "已允许" : "尚未确认"
            }
            guard report.configured, report.workspaceConfirmed,
                  report.checks.first(where: { $0.id == .configStore })?.state == .ok,
                  report.scanRoot.hasPrefix("/"), report.browseRoot.hasPrefix("/"),
                  deps.verifiesSingleGrant(report)
            else {
                clearScope()
                errorMessage = "仅可在已确认的单一代码目录与浏览范围上扩大授权。"
                return
            }
            configured = true
            scanRoot = URL(filePath: report.scanRoot, directoryHint: .isDirectory).resolvingSymlinksInPath()
            browseRoot = URL(filePath: report.browseRoot, directoryHint: .isDirectory).resolvingSymlinksInPath()
            if let preview = pendingPreview,
               preview.currentScanRoot.path != scanRoot?.path || preview.currentBrowseRoot.path != browseRoot?.path {
                pendingPreview = nil
            }
            errorMessage = nil
        } catch {
            localNetworkStatus = "尚未确认"
            clearScope()
            errorMessage = "未能确认当前授权范围，请刷新后重试。"
        }
    }

    private func clearScope() {
        configured = false
        scanRoot = nil
        browseRoot = nil
        pendingPreview = nil
    }

    /// 选中拟扩大的浏览目录后生成完整授权预览；此时绝不执行任何 CLI 写入。
    func prepareWidenPreview(proposedBrowseRoot: URL) {
        statusMessage = nil
        errorMessage = nil
        pendingPreview = nil
        guard canWidenBrowseScope, let scanRoot, let browseRoot else {
            errorMessage = "尚未读取到当前代码目录，请刷新后重试。"
            return
        }
        guard deps.directoryExists(proposedBrowseRoot) else {
            errorMessage = "请选择一个存在的文件夹。"
            return
        }
        let normalizedScan = scanRoot.standardizedFileURL
        let normalizedCurrentBrowse = browseRoot.standardizedFileURL
        let normalizedProposed = proposedBrowseRoot.resolvingSymlinksInPath().standardizedFileURL
        let normalizedHome = deps.homeDirectory().resolvingSymlinksInPath().standardizedFileURL

        guard Self.contains(parent: normalizedProposed, child: normalizedScan),
              Self.contains(parent: normalizedProposed, child: normalizedCurrentBrowse),
              normalizedProposed.path != normalizedCurrentBrowse.path else {
            errorMessage = "请选择同时包含当前代码目录与整个现有浏览范围的上级文件夹。"
            return
        }

        pendingPreview = WorkspaceBrowseScopePreview(
            currentScanRoot: normalizedScan,
            currentBrowseRoot: normalizedCurrentBrowse,
            proposedBrowseRoot: normalizedProposed,
            widensBeyondScanRoot: normalizedProposed.path != normalizedScan.path,
            coversHomeDirectory: Self.contains(parent: normalizedProposed, child: normalizedHome)
        )
    }

    /// 取消扩权：仅清理预览态，零写入且不影响已有配对。
    func cancelWidenPreview() {
        pendingPreview = nil
        errorMessage = nil
    }

    /// 用户看完完整授权范围并显式确认后，调用 `agentd workspace --scan-root ... --browse-root ...`。
    func confirmWidenBrowseScope() async {
        guard let preview = pendingPreview, !isApplying, !isLoading else { return }
        isApplying = true
        errorMessage = nil
        statusMessage = nil
        defer { isApplying = false }
        await refresh()
        guard pendingPreview == preview, deps.directoryExists(preview.proposedBrowseRoot),
              preview.proposedBrowseRoot.resolvingSymlinksInPath().standardizedFileURL.path == preview.proposedBrowseRoot.path
        else {
            pendingPreview = nil
            errorMessage = "当前授权范围已更改或无法确认，请重新预览。"
            return
        }
        do {
            try await deps.updateWorkspaceScope(preview.currentScanRoot, preview.proposedBrowseRoot)
            browseRoot = preview.proposedBrowseRoot
            pendingPreview = nil
            statusMessage = "已更新手机可浏览范围，现有设备配对保持不变。"
            do {
                try await deps.reloadIfRunning()
            } catch {
                statusMessage = nil
                errorMessage = "新浏览范围已保存，服务重载未完成。请重启服务以应用此次授权。"
            }
        } catch {
            if let clientError = error as? AgentClientError, let diag = clientError.onboardingDiagnostic {
                errorMessage = diag.message
            } else {
                errorMessage = "未能确认目录更新结果，请刷新范围后重试。"
            }
        }
    }

    static func contains(parent: URL, child: URL) -> Bool {
        let parentPath = parent.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        if parentPath == childPath {
            return true
        }
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return childPath.hasPrefix(prefix)
    }
}

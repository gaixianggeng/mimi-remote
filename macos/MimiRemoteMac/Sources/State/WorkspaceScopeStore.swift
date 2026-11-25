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
                try await hostStore.updateWorkspaceScope(scanRoot: scanRoot, browseRoot: browseRoot)
            },
            directoryExists: { url in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            },
            homeDirectory: {
                FileManager.default.homeDirectoryForCurrentUser
            }
        )
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
    private(set) var isLoading = false
    private(set) var isApplying = false
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?

    private let deps: WorkspaceScopeDependencies

    init(dependencies: WorkspaceScopeDependencies) {
        self.deps = dependencies
    }

    var canWidenBrowseScope: Bool {
        configured && scanRoot != nil && !isApplying
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let report = try await deps.preflight()
            configured = report.configured
            scanRoot = URL(filePath: report.scanRoot, directoryHint: .isDirectory)
            browseRoot = URL(filePath: report.browseRoot, directoryHint: .isDirectory)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            // 保持已有展示；不把底层报错原文直接暴露给用户。
            if let clientError = error as? AgentClientError, let diag = clientError.onboardingDiagnostic {
                errorMessage = diag.message
            }
        }
    }

    /// 选中拟扩大的浏览目录后生成完整授权预览；此时绝不执行任何 CLI 写入。
    func prepareWidenPreview(proposedBrowseRoot: URL) {
        statusMessage = nil
        errorMessage = nil
        guard let scanRoot else {
            errorMessage = "尚未读取到当前代码目录，请刷新后重试。"
            return
        }
        guard deps.directoryExists(proposedBrowseRoot) else {
            errorMessage = "请选择一个存在的文件夹。"
            return
        }
        let normalizedScan = scanRoot.standardizedFileURL
        let normalizedCurrentBrowse = (browseRoot ?? scanRoot).standardizedFileURL
        let normalizedProposed = proposedBrowseRoot.standardizedFileURL
        let normalizedHome = deps.homeDirectory().standardizedFileURL

        guard Self.contains(parent: normalizedProposed, child: normalizedScan) else {
            errorMessage = "所选浏览范围必须包含当前代码目录（\(normalizedScan.path)）。"
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
        guard let preview = pendingPreview, !isApplying else { return }
        isApplying = true
        errorMessage = nil
        statusMessage = nil
        defer { isApplying = false }
        do {
            try await deps.updateWorkspaceScope(preview.currentScanRoot, preview.proposedBrowseRoot)
            browseRoot = preview.proposedBrowseRoot
            pendingPreview = nil
            statusMessage = "已更新手机可浏览范围，现有设备配对保持不变。"
            await refresh()
        } catch is CancellationError {
            return
        } catch {
            if let clientError = error as? AgentClientError, let diag = clientError.onboardingDiagnostic {
                errorMessage = diag.message
            } else {
                errorMessage = "未能更新代码浏览范围，原有授权与配对保持不变。"
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

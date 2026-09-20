#if DEBUG
import Foundation

/// 统一解析仅用于本地开发与视觉验收的启动参数。
///
/// 将调试配置与 AppStore 的生产状态职责分离，避免预览能力继续扩大核心状态文件。
struct DebugLaunchConfiguration {
    /// H11 只允许测试进程通过显式参数打开；不接受环境变量、持久配置或远端下发。
    let usesNativeHarnessTestPath: Bool
    let opensWorkbenchWithoutPairing: Bool
    let seedsWorkbenchUI: Bool
    let seedsStoreScreenshotUI: Bool
    let seedsQueuedTurnsUI: Bool
    let seedsMCPApprovalUI: Bool
    let seedsHistoryUnreadUI: Bool
    // TODO(工作区行样式评审): 只服务 A/B/C 三版对比截图，定稿后删除这两个字段。
    let seedsDenseWorkspaceUI: Bool
    let workspaceRowStyle: String?
    let hostPlatformPreview: HostPlatform?
    let endpoint: String?
    let token: String?

    /// 工厂与开关由同一份不可变启动配置派生，避免 AppStore 与 SessionStore
    /// 各自判断后出现“一边已路由、一边仍关闭”的半接线状态。
    var nativeHarnessFactory: HarnessSessionClientFactory? {
        usesNativeHarnessTestPath ? HarnessSessionAPIClient.controlledTestFactory : nil
    }

    /// App Store 截图只使用公开的演示档案，并且只写入 AppStore 本次进程的内存态。
    /// 这样真实 Mac 名称、MagicDNS、IP 和访问码不会进入截图或持久化存储。
    func applyStoreScreenshotFixture(
        profiles: inout [ConnectionProfile],
        activeProfileID: inout String?,
        endpoint: inout String,
        token: inout String
    ) {
        guard seedsStoreScreenshotUI else { return }
        let primaryProfile = ConnectionProfile(
            id: "debug-store-primary",
            displayName: "Demo Mac Studio",
            endpoint: "http://100.64.0.10:8787",
            tailscaleDNSName: "demo-studio.example.ts.net",
            tailscaleDeviceName: "demo-studio",
            isDisplayNameCustomized: true,
            lastSuccessfulAt: Date(),
            installationID: "debug-store-primary-installation",
            hostPlatform: .apple
        )
        let secondaryProfile = ConnectionProfile(
            id: "debug-store-secondary",
            displayName: "Travel MacBook",
            endpoint: "http://100.64.0.11:8787",
            tailscaleDNSName: "travel-mac.example.ts.net",
            tailscaleDeviceName: "travel-mac",
            isDisplayNameCustomized: true,
            lastSuccessfulAt: Date().addingTimeInterval(-86_400),
            installationID: "debug-store-secondary-installation",
            hostPlatform: .apple
        )
        profiles = [primaryProfile, secondaryProfile]
        activeProfileID = primaryProfile.id
        endpoint = primaryProfile.endpoint
        token = "debug-store-placeholder-token"
    }

    /// 截图模式下的连接检查始终发布稳定成功态，禁止把演示地址发到真实网络。
    @discardableResult
    func applyStoreScreenshotConnectionState(
        status: inout ConnectionStatus,
        lastError: inout String?
    ) -> Bool {
        guard seedsStoreScreenshotUI else { return false }
        status = .connected("Demo Mac Studio")
        lastError = nil
        return true
    }

    /// 截图模式回到前台时恢复占位凭据，并复用稳定的离线连接状态。
    @discardableResult
    func restoreStoreScreenshotCredentials(
        token: inout String,
        isCredentialMemorySuspended: inout Bool,
        connectionStatus: inout ConnectionStatus,
        lastError: inout String?
    ) -> Bool {
        guard seedsStoreScreenshotUI else { return false }
        token = "debug-store-placeholder-token"
        isCredentialMemorySuspended = false
        _ = applyStoreScreenshotConnectionState(status: &connectionStatus, lastError: &lastError)
        return true
    }

    static func current(processInfo: ProcessInfo = .processInfo) -> DebugLaunchConfiguration {
        parse(arguments: processInfo.arguments, environment: processInfo.environment)
    }

    static func parse(
        arguments: [String],
        environment: [String: String]
    ) -> DebugLaunchConfiguration {
        let seedsQueuedTurnsUI = arguments.contains("--debug-seed-queue-ui")
            || boolValue(environment["MIMI_DEBUG_SEED_QUEUE_UI"])
        let seedsMCPApprovalUI = arguments.contains("--debug-seed-mcp-approval-ui")
            || boolValue(environment["MIMI_DEBUG_SEED_MCP_APPROVAL_UI"])
        let seedsHistoryUnreadUI = arguments.contains("--debug-seed-history-unread-ui")
            || boolValue(environment["MIMI_DEBUG_SEED_HISTORY_UNREAD_UI"])
        let seedsDenseWorkspaceUI = arguments.contains("--debug-seed-dense-workspace-ui")
            || boolValue(environment["MIMI_DEBUG_SEED_DENSE_WORKSPACE_UI"])
        let hostPlatformPreview = argumentValue(named: "--debug-host-platform", in: arguments)
            .map { HostPlatform(serverValue: $0) }
        return DebugLaunchConfiguration(
            usesNativeHarnessTestPath: arguments.contains("--test-native-harness"),
            opensWorkbenchWithoutPairing: arguments.contains("--debug-skip-pairing")
                || boolValue(environment["MIMI_DEBUG_SKIP_PAIRING"])
                || hostPlatformPreview != nil,
            seedsWorkbenchUI: arguments.contains("--debug-seed-ui")
                || boolValue(environment["MIMI_DEBUG_SEED_UI"])
                || seedsQueuedTurnsUI
                || seedsMCPApprovalUI
                || seedsHistoryUnreadUI
                || seedsDenseWorkspaceUI,
            seedsStoreScreenshotUI: arguments.contains("--debug-seed-store-ui")
                || boolValue(environment["MIMI_DEBUG_SEED_STORE_UI"]),
            seedsQueuedTurnsUI: seedsQueuedTurnsUI,
            seedsMCPApprovalUI: seedsMCPApprovalUI,
            seedsHistoryUnreadUI: seedsHistoryUnreadUI,
            seedsDenseWorkspaceUI: seedsDenseWorkspaceUI,
            workspaceRowStyle: argumentValue(named: "--debug-workspace-row-style", in: arguments)
                ?? environment["MIMI_DEBUG_WORKSPACE_ROW_STYLE"],
            hostPlatformPreview: hostPlatformPreview,
            endpoint: argumentValue(named: "--debug-endpoint", in: arguments)
                ?? environment["MIMI_DEBUG_ENDPOINT"],
            token: argumentValue(named: "--debug-token", in: arguments)
                ?? environment["MIMI_DEBUG_TOKEN"]
        )
    }

    private static func argumentValue(named name: String, in arguments: [String]) -> String? {
        let inlinePrefix = "\(name)="
        if let inlineValue = arguments.first(where: { $0.hasPrefix(inlinePrefix) }) {
            let value = String(inlineValue.dropFirst(inlinePrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        guard let index = arguments.firstIndex(of: name) else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex),
              !arguments[valueIndex].hasPrefix("--") else {
            return nil
        }
        let value = arguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func boolValue(_ rawValue: String?) -> Bool {
        switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "y", "on":
            return true
        default:
            return false
        }
    }
}
#endif

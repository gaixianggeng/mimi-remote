import AppKit
import Foundation

/// launchctl 的最小依赖面。测试通过替换这三个闭包，不会触碰真实的 GUI launchd
/// 环境；正式实现只调用 /bin/launchctl，不经过 shell 或用户 PATH。
struct CodexDesktopLaunchctlClient {
    var getenv: @MainActor (_ key: String) async throws -> String?
    var setenv: @MainActor (_ key: String, _ value: String) async throws -> Void
    var unsetenv: @MainActor (_ key: String) async throws -> Void

    @MainActor
    static func live(executor: ProcessExecutor = .shared) -> CodexDesktopLaunchctlClient {
        let launchctl = URL(filePath: "/bin/launchctl")
        let environment = ProcessEnvironment.userTooling

        @MainActor
        func read(_ arguments: [String]) async throws -> CommandResult {
            try await executor.run(
                executable: launchctl,
                arguments: arguments,
                timeout: .seconds(10),
                environment: environment
            )
        }

        @MainActor
        func mutate(_ arguments: [String]) async throws -> CommandResult {
            // launchctl 可能已经写入 GUI launchd 环境后才观察到调用方取消。
            // 必须等到命令真实结束，事务层才能继续完成三键写入或可靠回滚。
            try await executor.runToCompletion(
                executable: launchctl,
                arguments: arguments,
                timeout: .seconds(10),
                environment: environment
            )
        }

        return CodexDesktopLaunchctlClient(
            getenv: { key in
                let result = try await read(["getenv", key])
                if result.status == 0 {
                    let value = result.stdoutText
                        .trimmingCharacters(in: .newlines)
                    return value.isEmpty ? nil : value
                }

                // launchctl getenv 对不存在的变量返回非零且通常没有 stderr；
                // 只有空 stderr 才按“未设置”处理，避免把权限/系统错误吞掉。
                let detail = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                if result.status == 1, detail.isEmpty { return nil }
                throw CodexDesktopIntegrationError.launchctlFailed(
                    operation: "读取",
                    detail: detail
                )
            },
            setenv: { key, value in
                let result = try await mutate([
                    "setenv",
                    key,
                    value,
                ])
                guard result.status == 0 else {
                    throw CodexDesktopIntegrationError.launchctlFailed(
                        operation: "设置",
                        detail: result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
            },
            unsetenv: { key in
                let result = try await mutate([
                    "unsetenv",
                    key,
                ])
                guard result.status == 0 else {
                    throw CodexDesktopIntegrationError.launchctlFailed(
                        operation: "恢复",
                        detail: result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
            }
        )
    }
}

struct CodexDesktopApplicationInfo: Equatable, Sendable {
    let bundleURL: URL?
    let isRunning: Bool
    let launchDate: Date?

    init(bundleURL: URL?, isRunning: Bool, launchDate: Date? = nil) {
        self.bundleURL = bundleURL
        self.isRunning = isRunning
        self.launchDate = launchDate
    }

    var isInstalled: Bool { bundleURL != nil }
}

/// NSWorkspace/NSRunningApplication 也通过闭包注入，测试可以只记录 terminate/open
/// 顺序，而不会真的关闭用户的 Codex Desktop 或启动第二个实例。
struct CodexDesktopApplicationClient {
    var current: @MainActor () -> CodexDesktopApplicationInfo
    var terminateAndWait: @MainActor (_ bundleURL: URL) async throws -> Void
    var open: @MainActor (_ bundleURL: URL, _ environment: [String: String]) async throws -> Void

    @MainActor
    static func live(
        bundleIdentifier: String = CodexDesktopIntegrationClient.bundleIdentifier
    ) -> CodexDesktopApplicationClient {
        let workspace = NSWorkspace.shared
        let current: @MainActor () -> CodexDesktopApplicationInfo = {
            let running = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifier)
            let bundleURL = running.first?.bundleURL
                ?? workspace.urlForApplication(withBundleIdentifier: bundleIdentifier)
            return CodexDesktopApplicationInfo(
                bundleURL: bundleURL,
                isRunning: !running.isEmpty,
                // 多实例时取最早启动时间，pending 判断仍然覆盖整个 bundle
                // 的旧进程集合，而不是只观察列表中的第一个实例。
                launchDate: running.compactMap(\.launchDate).min()
            )
        }
        let terminateAndWait: @MainActor (URL) async throws -> Void = { _ in
            // 一个 bundle id 可能因旧版本/恢复状态短暂存在多个实例。必须对
            // 全部实例发送普通 terminate，再等待全部 terminated，不能只退出列表
            // 中第一个后就启动新实例，否则会并存两个 Codex Desktop。
            let running = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifier)
            guard !running.isEmpty else { return }
            for application in running where !application.isTerminated {
                guard application.terminate() else {
                    // 这里只请求普通 terminate；用户拒绝或 App 不响应时不能
                    // forceTerminate，否则可能丢失 Desktop 尚未写入磁盘的会话状态。
                    throw CodexDesktopIntegrationError.terminationRefused
                }
            }
            for attempt in 0..<120 {
                let remaining = NSRunningApplication
                    .runningApplications(withBundleIdentifier: bundleIdentifier)
                    .filter { !$0.isTerminated }
                if remaining.isEmpty { return }
                if attempt < 119 {
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            throw CodexDesktopIntegrationError.terminationTimedOut
        }
        @MainActor
        func openApplication(
            _ bundleURL: URL,
            _ environment: [String: String]
        ) async throws {
            let configuration = NSWorkspace.OpenConfiguration()
            // false 确保已存在的同 bundle 实例不会被并存启动；调用方已经
            // 等待旧实例 terminated，环境字典只注入本次新进程。
            configuration.createsNewApplicationInstance = false
            configuration.environment = environment
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                workspace.openApplication(
                    at: bundleURL,
                    configuration: configuration
                ) { _, error in
                    if let error {
                        continuation.resume(
                            throwing: CodexDesktopIntegrationError.openFailed(
                                error.localizedDescription
                            )
                        )
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
        let open: @MainActor (URL, [String: String]) async throws -> Void = openApplication
        return CodexDesktopApplicationClient(
            current: current,
            terminateAndWait: terminateAndWait,
            open: open
        )
    }
}

struct CodexDesktopIntegrationClient {
    static let bundleIdentifier = "com.openai.codex"
    static let environmentKey = "CODEX_APP_SERVER_USE_LOCAL_DAEMON"
    static let codexHomeKey = "CODEX_HOME"
    /// Mimi 自己的会话 ownership 标记，不会传给 Codex 作为配置。
    /// launchd 在注销/登录时可能清空官方两键；随机 epoch 让新会话中
    /// 外部恰好写入相同官方值时不能被误认成 Mimi 的旧 ownership。
    static let ownershipEpochKey = "MIMI_REMOTE_CODEX_DESKTOP_OWNERSHIP_EPOCH"

    var inspect: @MainActor () async throws -> CodexDesktopEnvironmentSnapshot
    var bootstrap: @MainActor () async throws -> CodexDesktopEnvironmentSnapshot
    var setEnabled: @MainActor (_ enabled: Bool, _ codexHome: String?) async throws -> CodexDesktopEnvironmentSnapshot
    var restartAndApply: @MainActor () async throws -> CodexDesktopEnvironmentSnapshot

    init(
        inspect: @escaping @MainActor () async throws -> CodexDesktopEnvironmentSnapshot,
        bootstrap: @escaping @MainActor () async throws -> CodexDesktopEnvironmentSnapshot,
        setEnabled: @escaping @MainActor (_ enabled: Bool, _ codexHome: String?) async throws -> CodexDesktopEnvironmentSnapshot,
        restartAndApply: @escaping @MainActor () async throws -> CodexDesktopEnvironmentSnapshot
    ) {
        self.inspect = inspect
        self.bootstrap = bootstrap
        self.setEnabled = setEnabled
        self.restartAndApply = restartAndApply
    }

    /// 预览和单元测试使用的无副作用实现。默认保持关闭，不会假装 backend
    /// 已共享，也不会查询/修改真实 Desktop 或 launchd。
    static var noop: CodexDesktopIntegrationClient {
        let snapshot = CodexDesktopEnvironmentSnapshot(enabled: false)
        return CodexDesktopIntegrationClient(
            inspect: { snapshot },
            bootstrap: { snapshot },
            setEnabled: { enabled, _ in
                CodexDesktopEnvironmentSnapshot(enabled: enabled)
            },
            restartAndApply: { snapshot }
        )
    }

    @MainActor
    static func live(
        defaults: UserDefaults = .standard,
        launchctl: CodexDesktopLaunchctlClient? = nil,
        application: CodexDesktopApplicationClient? = nil
    ) -> CodexDesktopIntegrationClient {
        let runtime = CodexDesktopIntegrationRuntime(
            defaults: defaults,
            launchctl: launchctl ?? .live(),
            application: application ?? .live()
        )
        return CodexDesktopIntegrationClient(
            inspect: { try await runtime.inspect() },
            bootstrap: { try await runtime.bootstrap() },
            setEnabled: { enabled, codexHome in
                try await runtime.setEnabled(enabled, codexHome: codexHome)
            },
            restartAndApply: { try await runtime.restartAndApply() }
        )
    }
}

private enum CodexDesktopIntegrationError: LocalizedError, Equatable {
    case launchctlFailed(operation: String, detail: String)
    case externalEnvironmentConflict(key: String, value: String)
    case codexHomeMissing
    case appNotInstalled
    case terminationRefused
    case terminationTimedOut
    case openFailed(String)
    case rollbackFailed(operation: String, original: String, rollback: String)

    var errorDescription: String? {
        switch self {
        case .launchctlFailed(let operation, let detail):
            if detail.isEmpty {
                return "无法\(operation) Codex Desktop 共享环境。"
            }
            return "无法\(operation) Codex Desktop 共享环境：\(detail)"
        case .externalEnvironmentConflict(let key, let value):
            return "\(key) 已被其他程序设置为“\(value)”；为避免覆盖外部配置，Mimi Remote 未自动修改。"
        case .codexHomeMissing:
            return "agentd 未返回 Codex Desktop 使用的 CODEX_HOME，已停止配置以避免指向错误会话目录。"
        case .appNotInstalled:
            return "未找到 bundle id 为 com.openai.codex 的 Codex Desktop。"
        case .terminationRefused:
            return "Codex Desktop 拒绝退出；未强制终止，请先在 Desktop 中保存并退出后重试。"
        case .terminationTimedOut:
            return "等待 Codex Desktop 完全退出超时；未启动第二个实例，请稍后重试。"
        case .openFailed(let detail):
            return "无法重新启动 Codex Desktop：\(detail)"
        case .rollbackFailed(let operation, let original, let rollback):
            return "\(operation)失败：\(original)；自动恢复也失败：\(rollback)。请不要重启 Codex Desktop，先重试或检查系统环境。"
        }
    }
}

@MainActor
private final class CodexDesktopIntegrationRuntime {
    private let defaults: UserDefaults
    private let launchctl: CodexDesktopLaunchctlClient
    private let application: CodexDesktopApplicationClient

    private static let enabledKey = "MimiRemoteMac.codexDesktop.enabled"
    private static let previousValueKey = "MimiRemoteMac.codexDesktop.previousValue"
    private static let writtenValueKey = "MimiRemoteMac.codexDesktop.writtenValue"
    private static let ownsEnvironmentKey = "MimiRemoteMac.codexDesktop.ownsEnvironment"
    private static let previousCodexHomeKey = "MimiRemoteMac.codexDesktop.previousCodexHome"
    private static let writtenCodexHomeKey = "MimiRemoteMac.codexDesktop.writtenCodexHome"
    private static let ownsCodexHomeKey = "MimiRemoteMac.codexDesktop.ownsCodexHome"
    private static let writtenSessionEpochKey = "MimiRemoteMac.codexDesktop.writtenSessionEpoch"
    private static let ownsSessionEpochKey = "MimiRemoteMac.codexDesktop.ownsSessionEpoch"
    private static let canonicalCodexHomeKey = "MimiRemoteMac.codexDesktop.codexHome"
    private static let restartRequiredAtKey = "MimiRemoteMac.codexDesktop.restartRequiredAt"

    init(
        defaults: UserDefaults,
        launchctl: CodexDesktopLaunchctlClient,
        application: CodexDesktopApplicationClient
    ) {
        self.defaults = defaults
        self.launchctl = launchctl
        self.application = application
    }

    func inspect() async throws -> CodexDesktopEnvironmentSnapshot {
        try await makeSnapshot(
            environmentValue: launchctl.getenv(CodexDesktopIntegrationClient.environmentKey),
            codexHome: launchctl.getenv(CodexDesktopIntegrationClient.codexHomeKey),
            sessionEpoch: launchctl.getenv(CodexDesktopIntegrationClient.ownershipEpochKey)
        )
    }

    func bootstrap() async throws -> CodexDesktopEnvironmentSnapshot {
        // bootstrap 只读取偏好和当前 launchd/Desktop 状态；是否自动写入环境
        // 由 HostStore 结合 agentd runtime.shared 决定，避免把既有 WS 用户静默
        // 切换到本地 daemon。它永远不会终止或启动 Codex Desktop。
        return try await inspect()
    }

    func setEnabled(
        _ enabled: Bool,
        codexHome: String?
    ) async throws -> CodexDesktopEnvironmentSnapshot {
        let nextCodexHome = normalized(codexHome) ?? canonicalCodexHome
        // 两个 launchd 键和 ownership epoch 都成功后才提交用户偏好。否则 UI
        // 会保持原状态，applyPreference 负责回滚已经写入的键，避免半配置。
        // applyPreference 返回的快照包含本次提交已知值；提交后不能再次调用
        // launchctl getenv，否则瞬时读取失败会把“已写入”误判成失败，令上层
        // 只回滚 agentd 而留下 Desktop 环境分裂。
        let appliedSnapshot = try await applyPreference(
            enabled,
            codexHome: nextCodexHome
        )
        defaults.set(enabled, forKey: Self.enabledKey)
        if let nextCodexHome {
            defaults.set(nextCodexHome, forKey: Self.canonicalCodexHomeKey)
        }
        let applicationInfo = application.current()
        if applicationInfo.isRunning {
            defaults.set(Date().timeIntervalSince1970, forKey: Self.restartRequiredAtKey)
        } else {
            defaults.removeObject(forKey: Self.restartRequiredAtKey)
        }
        return try await makeSnapshot(
            environmentValue: appliedSnapshot.environmentValue,
            codexHome: appliedSnapshot.codexHome,
            sessionEpoch: appliedSnapshot.sessionEpoch
        )
    }

    func restartAndApply() async throws -> CodexDesktopEnvironmentSnapshot {
        let snapshot = try await applyPreference(
            preferenceEnabled,
            codexHome: canonicalCodexHome
        )
        guard let bundleURL = snapshot.bundleURL else {
            throw CodexDesktopIntegrationError.appNotInstalled
        }

        if snapshot.appRunning {
            // terminateAndWait 内部只调用普通 NSRunningApplication.terminate，并等待
            // terminated；没有 forceTerminate，也不会在旧进程存活时开第二个实例。
            try await application.terminateAndWait(bundleURL)
        }

        // launchd 环境是 Dock/Finder 的长期保险；OpenConfiguration.environment
        // 是本次新实例的短期保险。禁用时传空字典，绝不注入官方开关。
        var environment: [String: String] = [:]
        if snapshot.enabled {
            environment[CodexDesktopIntegrationClient.environmentKey] = "1"
            if let codexHome = snapshot.codexHome {
                environment[CodexDesktopIntegrationClient.codexHomeKey] = codexHome
            }
        }
        try await application.open(bundleURL, environment)
        defaults.removeObject(forKey: Self.restartRequiredAtKey)
        // open 已成功提交本次新进程；这里同样使用 applyPreference 的已知环境
        // 快照，避免一次无关的 getenv 瞬时失败制造“重启失败”的假象。
        return try await makeSnapshot(
            environmentValue: snapshot.environmentValue,
            codexHome: snapshot.codexHome,
            sessionEpoch: snapshot.sessionEpoch
        )
    }

    private var hasLocalPreference: Bool {
        defaults.object(forKey: Self.enabledKey) != nil
    }

    private var preferenceEnabled: Bool {
        defaults.object(forKey: Self.enabledKey) == nil
            ? false
            : defaults.bool(forKey: Self.enabledKey)
    }

    private var previousValue: String? {
        defaults.string(forKey: Self.previousValueKey)
    }

    private var writtenValue: String? {
        defaults.string(forKey: Self.writtenValueKey)
    }

    private var ownsEnvironment: Bool {
        defaults.bool(forKey: Self.ownsEnvironmentKey)
    }

    private var previousCodexHome: String? {
        defaults.string(forKey: Self.previousCodexHomeKey)
    }

    private var writtenCodexHome: String? {
        defaults.string(forKey: Self.writtenCodexHomeKey)
    }

    private var ownsCodexHome: Bool {
        defaults.bool(forKey: Self.ownsCodexHomeKey)
    }

    private var writtenSessionEpoch: String? {
        defaults.string(forKey: Self.writtenSessionEpochKey)
    }

    private var ownsSessionEpoch: Bool {
        defaults.bool(forKey: Self.ownsSessionEpochKey)
    }

    private var canonicalCodexHome: String? {
        defaults.string(forKey: Self.canonicalCodexHomeKey)
    }

    /// 旧版只记录了 daemon flag 的 ownership，没有 CODEX_HOME 或会话 epoch。
    /// 只有在偏好仍为启用、且所有新版账本字段都不存在时，才能证明这条
    /// `writtenValue == "1"` 确实来自 Mimi；一次性迁移会保留 daemon ownership，
    /// 再补写 canonical CODEX_HOME 和新的随机 epoch。更宽松的判断会把新会话
    /// 中其他程序写入的同值配置误认成 Mimi，因而必须保持 fail-closed。
    private var isLegacyDaemonOnlyOwnershipLedger: Bool {
        guard
            let enabled = defaults.object(forKey: Self.enabledKey) as? Bool,
            enabled,
            let written = defaults.object(forKey: Self.writtenValueKey) as? String,
            written == "1",
            let ownsDaemon = defaults.object(forKey: Self.ownsEnvironmentKey) as? Bool,
            ownsDaemon
        else {
            return false
        }

        // 不能用 bool(forKey:) / string(forKey:) 推断“字段不存在”：UserDefaults
        // 会把显式 false、空字符串或错误类型映射成 false/nil，从而把部分新版
        // 账本误认作旧版。只要任一新版 ownership 字段曾落盘，就拒绝迁移。
        let newerOwnershipKeys = [
            Self.previousValueKey,
            Self.previousCodexHomeKey,
            Self.writtenCodexHomeKey,
            Self.ownsCodexHomeKey,
            Self.writtenSessionEpochKey,
            Self.ownsSessionEpochKey,
            Self.canonicalCodexHomeKey,
        ]
        return newerOwnershipKeys.allSatisfy {
            defaults.object(forKey: $0) == nil
        }
    }

    private func applyPreference(
        _ enabled: Bool,
        codexHome: String?
    ) async throws -> CodexDesktopEnvironmentSnapshot {
        let current = normalized(try await launchctl.getenv(CodexDesktopIntegrationClient.environmentKey))
        let currentCodexHome = normalized(try await launchctl.getenv(CodexDesktopIntegrationClient.codexHomeKey))
        let currentSessionEpoch = normalized(
            try await launchctl.getenv(CodexDesktopIntegrationClient.ownershipEpochKey)
        )

        if enabled {
            guard let codexHome else { throw CodexDesktopIntegrationError.codexHomeMissing }

            let hadDaemonOwnership = ownsEnvironment && writtenValue == "1"
            let hadCodexHomeOwnership = ownsCodexHome && writtenCodexHome != nil
            let hadAnyOwnership = hadDaemonOwnership
                || hadCodexHomeOwnership
                || (ownsSessionEpoch && writtenSessionEpoch != nil)
            let officialValuesAreEmpty = current == nil
                && currentCodexHome == nil
            let currentEpochIsOwned = ownsSessionEpoch
                && currentSessionEpoch != nil
                && currentSessionEpoch == writtenSessionEpoch
            let sessionResetIsSafe = officialValuesAreEmpty
                && currentSessionEpoch == nil
            let isLegacyMigration = isLegacyDaemonOnlyOwnershipLedger
                && current == "1"
                && currentCodexHome == nil
                && currentSessionEpoch == nil

            // 同一登录会话里，Mimi 之前写入的值一旦被清空/改写，就视为外部
            // 变更。只有三个值都为空时才可能是注销/登录造成的 launchd 重置，
            // 此时显式 Toggle 可以生成全新的 epoch 重新取得 ownership。
            if hadDaemonOwnership,
               current != writtenValue,
               !sessionResetIsSafe
            {
                throw externalConflictWithoutClearing(
                    CodexDesktopIntegrationClient.environmentKey,
                    current ?? "(已被外部清除)"
                )
            }
            if hadCodexHomeOwnership,
               currentCodexHome != writtenCodexHome,
               !sessionResetIsSafe
            {
                throw externalConflictWithoutClearing(
                    CodexDesktopIntegrationClient.codexHomeKey,
                    currentCodexHome ?? "(已被外部清除)"
                )
            }
            if hadAnyOwnership,
               !sessionResetIsSafe,
               !currentEpochIsOwned,
               !isLegacyMigration,
               (current == writtenValue || currentCodexHome == writtenCodexHome)
            {
                // 两个官方值即使“恰好相同”，新会话里没有 Mimi 的 epoch 也不能
                // 认领，避免误删其他程序刚写入的相同配置。
                throw externalConflictWithoutClearing(
                    CodexDesktopIntegrationClient.ownershipEpochKey,
                    currentSessionEpoch ?? "(新登录会话)"
                )
            }

            let daemonNeedsWrite = current == nil
            let codexHomeNeedsWrite = currentCodexHome == nil
            if let current, current != "1" {
                throw externalConflictWithoutClearing(
                    CodexDesktopIntegrationClient.environmentKey,
                    current
                )
            }
            if current == "1", !hadDaemonOwnership {
                // 没有旧 Mimi ledger 时，不能因为外部恰好写入了 "1" 就认领
                // daemon flag；这也覆盖了 CODEX_HOME 尚为空的部分配置。
                throw externalConflictWithoutClearing(
                    CodexDesktopIntegrationClient.environmentKey,
                    current ?? "(已被外部清除)"
                )
            }
            if let currentCodexHome, currentCodexHome != codexHome {
                throw externalConflictWithoutClearing(
                    CodexDesktopIntegrationClient.codexHomeKey,
                    currentCodexHome
                )
            }

            let needsMimiWrite = daemonNeedsWrite || codexHomeNeedsWrite
            var nextSessionEpoch = currentSessionEpoch
            var writesSessionEpoch = false
            if needsMimiWrite {
                if sessionResetIsSafe {
                    // 显式恢复新登录会话时不复用旧 epoch，让下一次禁用只能
                    // 匹配本次新写入的值。
                    nextSessionEpoch = UUID().uuidString
                    writesSessionEpoch = true
                } else if let currentSessionEpoch {
                    guard currentEpochIsOwned else {
                        throw externalConflictWithoutClearing(
                            CodexDesktopIntegrationClient.ownershipEpochKey,
                            currentSessionEpoch
                        )
                    }
                } else {
                    // 首次启用使用新随机值；不复用旧会话 epoch，避免新会话
                    // 外部同值被视为旧 ownership。
                    nextSessionEpoch = UUID().uuidString
                    writesSessionEpoch = true
                }
            }

            // launchctl 写入是一个小事务：任一官方键或 epoch 失败，都按相反顺序
            // 恢复已写入的键，避免留下只设置了开关却没有 CODEX_HOME 的半配置。
            var writes: [(key: String, previous: String?)] = []
            do {
                if daemonNeedsWrite {
                    try await launchctl.setenv(
                        CodexDesktopIntegrationClient.environmentKey,
                        "1"
                    )
                    writes.append((CodexDesktopIntegrationClient.environmentKey, current))
                }
                if codexHomeNeedsWrite {
                    try await launchctl.setenv(
                        CodexDesktopIntegrationClient.codexHomeKey,
                        codexHome
                    )
                    writes.append((CodexDesktopIntegrationClient.codexHomeKey, currentCodexHome))
                }
                if writesSessionEpoch, let nextSessionEpoch {
                    try await launchctl.setenv(
                        CodexDesktopIntegrationClient.ownershipEpochKey,
                        nextSessionEpoch
                    )
                    writes.append((CodexDesktopIntegrationClient.ownershipEpochKey, currentSessionEpoch))
                }
            } catch {
                do {
                    for write in writes.reversed() {
                        try await restore(key: write.key, previous: write.previous)
                    }
                } catch let rollbackError {
                    throw CodexDesktopIntegrationError.rollbackFailed(
                        operation: "配置 Codex Desktop 共享环境",
                        original: error.localizedDescription,
                        rollback: rollbackError.localizedDescription
                    )
                }
                throw error
            }

            if daemonNeedsWrite {
                storeOwnership(
                    previousKey: Self.previousValueKey,
                    previous: current,
                    writtenKey: Self.writtenValueKey,
                    written: "1",
                    ownsKey: Self.ownsEnvironmentKey
                )
            } else if !hadDaemonOwnership && !isLegacyMigration {
                clearDaemonOwnership(keepPrevious: false)
            }
            if codexHomeNeedsWrite {
                storeOwnership(
                    previousKey: Self.previousCodexHomeKey,
                    previous: currentCodexHome,
                    writtenKey: Self.writtenCodexHomeKey,
                    written: codexHome,
                    ownsKey: Self.ownsCodexHomeKey
                )
            } else if !(hadCodexHomeOwnership && currentEpochIsOwned) {
                clearCodexHomeOwnership(keepPrevious: false)
            }
            if needsMimiWrite {
                guard let nextSessionEpoch else {
                    throw CodexDesktopIntegrationError.launchctlFailed(
                        operation: "记录",
                        detail: "ownership epoch 为空"
                    )
                }
                defaults.set(nextSessionEpoch, forKey: Self.writtenSessionEpochKey)
                defaults.set(true, forKey: Self.ownsSessionEpochKey)
            } else if !currentEpochIsOwned {
                clearSessionOwnership()
            }
            return try await makeSnapshot(
                environmentValue: "1",
                codexHome: codexHome,
                sessionEpoch: nextSessionEpoch
            )
        }

        let didOwnDaemon = ownsEnvironment && writtenValue == "1"
        let didOwnCodexHome = ownsCodexHome && writtenCodexHome != nil
        let officialValuesAreEmpty = current == nil
            && currentCodexHome == nil
        let currentEpochIsOwned = ownsSessionEpoch
            && currentSessionEpoch != nil
            && currentSessionEpoch == writtenSessionEpoch
        let sessionResetIsSafe = officialValuesAreEmpty
            && (currentSessionEpoch == nil || currentEpochIsOwned)

		// 禁用时只要两个官方键都已为空，且 marker 为空或仍精确匹配 Mimi，
		// 就没有外部官方值会被误删；匹配的 marker 也可安全清理。启用路径更
		// 严格，必须三键全空才会把它认作新的登录会话并重新写入。
        if sessionResetIsSafe {
            if currentEpochIsOwned {
                // marker 仍匹配 Mimi 时可以安全清理；若 unset 失败则保留
                // UserDefaults ownership，下一次显式操作仍会 fail closed。
                try await restore(
                    key: CodexDesktopIntegrationClient.ownershipEpochKey,
                    previous: nil
                )
            }
            if didOwnDaemon { clearDaemonOwnership(keepPrevious: true) }
            if didOwnCodexHome { clearCodexHomeOwnership(keepPrevious: true) }
            if ownsSessionEpoch { clearSessionOwnership() }
            return try await makeSnapshot(
                environmentValue: nil,
                codexHome: nil,
                sessionEpoch: nil
            )
        }

        // 先同时验证两个 ownership，再开始恢复。任何一个键被外部改动时都不
        // 碰另一个键，确保一次开关操作不会产生可避免的半恢复状态。
        if didOwnDaemon, current != writtenValue {
            throw externalConflictWithoutClearing(
                CodexDesktopIntegrationClient.environmentKey,
                current ?? "(已被外部清除)"
            )
        }
        if didOwnCodexHome, currentCodexHome != writtenCodexHome {
            throw externalConflictWithoutClearing(
                CodexDesktopIntegrationClient.codexHomeKey,
                currentCodexHome ?? "(已被外部清除)"
            )
        }
        if (didOwnDaemon || didOwnCodexHome), !currentEpochIsOwned {
            throw externalConflictWithoutClearing(
                CodexDesktopIntegrationClient.ownershipEpochKey,
                currentSessionEpoch ?? "(新登录会话)"
            )
        }

        var writes: [(key: String, previous: String?)] = []
        do {
            if didOwnDaemon {
                try await restore(
                    key: CodexDesktopIntegrationClient.environmentKey,
                    previous: previousValue
                )
                writes.append((CodexDesktopIntegrationClient.environmentKey, current))
            }
            if didOwnCodexHome {
                try await restore(
                    key: CodexDesktopIntegrationClient.codexHomeKey,
                    previous: previousCodexHome
                )
                writes.append((CodexDesktopIntegrationClient.codexHomeKey, currentCodexHome))
            }
            if currentEpochIsOwned {
                // epoch 是 Mimi 的 ownership 标记，启用时只在 launchd 原来为空
                // 的情况下写入，因此禁用时只能清理仍匹配的这一值。
                try await restore(
                    key: CodexDesktopIntegrationClient.ownershipEpochKey,
                    previous: nil
                )
                writes.append((CodexDesktopIntegrationClient.ownershipEpochKey, currentSessionEpoch))
            }
        } catch {
            do {
                for write in writes.reversed() {
                    try await restore(key: write.key, previous: write.previous)
                }
            } catch let rollbackError {
                throw CodexDesktopIntegrationError.rollbackFailed(
                    operation: "关闭 Codex Desktop 共享环境",
                    original: error.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw error
        }
        if didOwnDaemon { clearDaemonOwnership(keepPrevious: true) }
        if didOwnCodexHome { clearCodexHomeOwnership(keepPrevious: true) }
        if currentEpochIsOwned { clearSessionOwnership() }
        return try await makeSnapshot(
            environmentValue: didOwnDaemon ? normalized(previousValue) : current,
            codexHome: didOwnCodexHome ? normalized(previousCodexHome) : currentCodexHome,
            sessionEpoch: nil
        )
    }

    private func restore(key: String, previous: String?) async throws {
        if let previous {
            try await launchctl.setenv(key, previous)
        } else {
            try await launchctl.unsetenv(key)
        }
    }

    private func storeOwnership(
        previousKey: String,
        previous: String?,
        writtenKey: String,
        written: String,
        ownsKey: String
    ) {
        if let previous { defaults.set(previous, forKey: previousKey) }
        else { defaults.removeObject(forKey: previousKey) }
        defaults.set(written, forKey: writtenKey)
        defaults.set(true, forKey: ownsKey)
    }

    private func makeSnapshot(
        environmentValue: String?,
        codexHome: String?,
        sessionEpoch: String?
    ) async throws -> CodexDesktopEnvironmentSnapshot {
        let resolvedSessionEpoch = normalized(sessionEpoch)
        let applicationInfo = application.current()
        let restartRequiredAt = defaults.double(forKey: Self.restartRequiredAtKey)
        var restartRequired = applicationInfo.isRunning && restartRequiredAt > 0
        if restartRequired,
           let launchDate = applicationInfo.launchDate,
           launchDate.timeIntervalSince1970 >= restartRequiredAt
        {
            // 用户也可能自行完全退出再从 Dock/Finder 重开。launchd 环境只在
            // 新进程创建时读取，因此新进程的 launchDate 晚于配置提交即可清账。
            restartRequired = false
            defaults.removeObject(forKey: Self.restartRequiredAtKey)
        } else if !applicationInfo.isRunning, restartRequiredAt > 0 {
            restartRequired = false
            defaults.removeObject(forKey: Self.restartRequiredAtKey)
        }
        let sessionOwnershipIsValid = ownsSessionEpoch
            && writtenSessionEpoch == resolvedSessionEpoch
        return CodexDesktopEnvironmentSnapshot(
            hasLocalPreference: hasLocalPreference,
            enabled: preferenceEnabled,
            environmentValue: normalized(environmentValue),
            codexHome: normalized(codexHome),
            previousValue: previousValue,
            previousCodexHome: previousCodexHome,
            writtenValue: writtenValue,
            writtenCodexHome: writtenCodexHome,
            // 官方键的 ownership 必须和当前登录会话 epoch 一起验证；即使
            // 新会话中外部恰好写入同样的值，也不能把旧 UserDefaults 记录当作
            // Mimi 仍然拥有。
            ownsEnvironment: sessionOwnershipIsValid
                && ownsEnvironment
                && writtenValue == "1",
            ownsCodexHome: sessionOwnershipIsValid
                && ownsCodexHome
                && writtenCodexHome != nil,
            sessionEpoch: resolvedSessionEpoch,
            writtenSessionEpoch: writtenSessionEpoch,
            ownsSessionEpoch: sessionOwnershipIsValid,
            appInstalled: applicationInfo.isInstalled,
            appRunning: applicationInfo.isRunning,
            restartRequired: restartRequired,
            bundleURL: applicationInfo.bundleURL
        )
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .newlines)
        return result.isEmpty ? nil : result
    }

    private func externalConflictWithoutClearing(
        _ key: String,
        _ current: String
    ) -> CodexDesktopIntegrationError {
        .externalEnvironmentConflict(key: key, value: current)
    }

    private func clearDaemonOwnership(keepPrevious: Bool) {
        if !keepPrevious {
            defaults.removeObject(forKey: Self.previousValueKey)
        }
        defaults.removeObject(forKey: Self.writtenValueKey)
        defaults.set(false, forKey: Self.ownsEnvironmentKey)
    }

    private func clearCodexHomeOwnership(keepPrevious: Bool) {
        if !keepPrevious {
            defaults.removeObject(forKey: Self.previousCodexHomeKey)
        }
        defaults.removeObject(forKey: Self.writtenCodexHomeKey)
        defaults.set(false, forKey: Self.ownsCodexHomeKey)
    }

    private func clearSessionOwnership() {
        defaults.removeObject(forKey: Self.writtenSessionEpochKey)
        defaults.set(false, forKey: Self.ownsSessionEpochKey)
    }

}

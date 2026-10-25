import Foundation

@MainActor
extension HostStore {
    var claudeTurnHintsEnabled: Bool {
        claudeTurnHintsConfiguration?.enabled ?? claudeConfiguration?.turnHintsEnabled ?? true
    }

    func setClaudeTurnHintsEnabled(_ enabled: Bool) async {
        guard !isBusy, owner == .macApp else {
            claudeError = "请先启动并接管 Mimi Remote Mac 服务。"
            return
        }
        guard claudeTurnHintsEnabled != enabled else { return }
        let runtimeWasEnabled = claudeEnabled
        isBusy = true
        isUpdatingClaude = true
        claudeError = nil
        invalidateModulePairing()
        defer {
            isUpdatingClaude = false
            isBusy = false
        }

        do {
            let result = try await agent.configureClaudeTurnHints(enabled)
            claudeTurnHintsConfiguration = result
            do {
                if result.restartRequired {
                    try await reloadMacAgentForConfigurationChange()
                    try await waitForClaudeRuntime(enabled: runtimeWasEnabled)
                }
            } catch {
                let updateError = error
                if result.changed {
                    let rolledBack = await rollbackClaudeTurnHintsConfiguration(
                        result,
                        runtimeWasEnabled: runtimeWasEnabled
                    )
                    claudeError = rolledBack
                        ? "更新 Claude 提示卡失败：\(updateError.localizedDescription) 已恢复修改前的设置。"
                        : "更新 Claude 提示卡失败：\(updateError.localizedDescription) 自动恢复也失败，请打开诊断后重试。"
                } else {
                    claudeError = "更新 Claude 提示卡失败：\(updateError.localizedDescription)"
                }
                await settleModuleChangeFailure(claudeError ?? updateError.localizedDescription)
            }
        } catch {
            claudeError = error.localizedDescription
            await settleModuleChangeFailure(error.localizedDescription)
        }
    }

    private func rollbackClaudeTurnHintsConfiguration(
        _ changed: ClaudeTurnHintsConfigurationResult,
        runtimeWasEnabled: Bool
    ) async -> Bool {
        do {
            let restored = try await agent.restoreClaudeTurnHints(changed)
            claudeTurnHintsConfiguration = restored
            if restored.restartRequired {
                try await reloadMacAgentForConfigurationChange()
                try await waitForClaudeRuntime(enabled: runtimeWasEnabled)
            }
            return true
        } catch {
            return false
        }
    }
}

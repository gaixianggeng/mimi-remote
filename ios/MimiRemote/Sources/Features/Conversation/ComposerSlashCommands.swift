import SwiftUI
import UIKit

/// `$` 技能补全与 `/` 命令菜单的数据和动作（#765）。
///
/// 命令只调用输入框已有入口（模型选择器、权限、计划模式、压缩上下文），
/// 不发聊天消息、不消耗模型回合；发送路径不解析命令文本，手打的 `/xxx` 仍按原样发送，
/// Claude 会话因此保留 SDK 自己解析斜杠命令的能力。
extension ComposerView {
    @ViewBuilder
    var composerAutocompleteOverlay: some View {
        let suggestions = autocompleteSuggestions
        if let query = activeSkillQuery, !suggestions.isEmpty {
            ComposerAutocompletePanel(
                trigger: query.trigger,
                suggestions: suggestions,
                selectedIndex: min(selectedSkillSuggestionIndex, suggestions.count - 1),
                // 约 4 行（iPhone）或 6 行（iPad），其余滚动，避免顶出可视区域。
                maxListHeight: isPhoneComposer ? 184 : 276,
                onSelect: { suggestion in
                    selectAutocompleteSuggestion(suggestion)
                }
            )
            .environmentObject(themeStore)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 8)
            // 零高度锚点贴住输入卡顶边，浮层按底边对齐向上展开；frame 不裁剪，超出部分仍可点按。
            .frame(height: 0, alignment: .bottom)
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
        }
    }

    var autocompleteSuggestions: [ComposerAutocompleteSuggestion] {
        guard let activeSkillQuery else { return [] }
        let skills = enabledSkillShortcuts
            .filter { !selectedSkillPaths.contains($0.path) }
            .map(ComposerAutocompleteSuggestion.skill)
        switch activeSkillQuery.trigger {
        case .skill:
            return ComposerAutocompleteRanking.rank(skills, query: activeSkillQuery.query)
        case .command:
            // 能力目录目前固定来自 Codex（#370），Claude 会话里不能把它当成 Claude 技能展示。
            let slashSkills = CodexAppServerSessionRuntime.normalizedRuntimeProvider(composerRuntimeProvider) == "codex"
                ? skills
                : []
            return ComposerAutocompleteRanking.rank(
                slashCommands.map(ComposerAutocompleteSuggestion.command) + slashSkills,
                query: activeSkillQuery.query
            )
        }
    }

    /// 只列出当前会话真实可用的入口；与工具栏使用同一组限制。
    var slashCommands: [ComposerSlashCommand] {
        var commands: [ComposerSlashCommand] = []
        let canEditTurnSettings = composerTurnSettingsPolicy.allowsTurnSettingsEditing
        if canEditTurnSettings {
            commands.append(ComposerSlashCommand(
                action: .model,
                name: "model",
                title: L10n.text("ui.switch_model"),
                detail: L10n.text("ui.switch_model_and_inference_strength"),
                systemImage: "cpu"
            ))
        }
        // 系统 Menu 无法用代码弹出，权限档位直接作为候选平铺，选中即生效。
        if canEditTurnSettings, availablePermissionModes.count > 1 {
            let currentMode = ComposerSlashCommand.currentPermissionMode(
                preservesThreadSettings: composerState.turnOptions.preservesThreadPermissionSettings,
                selectedMode: composerState.permissionMode,
                selectedProfileID: selectedPermissionProfileID,
                activeProfileID: activePermissionProfile?.id
            )
            for mode in availablePermissionModes {
                commands.append(ComposerSlashCommand(
                    action: .permission(mode),
                    name: "permissions",
                    title: mode.title,
                    detail: mode.detail,
                    systemImage: mode.systemImage,
                    isCurrent: mode == currentMode
                ))
            }
        }
        if canEditTurnSettings, RuntimeFeatureSupport.supportsPlanningAndGoals(for: composerRuntimeProvider) {
            commands.append(ComposerSlashCommand(
                action: .plan,
                name: "plan",
                title: L10n.text("ui.planning_mode"),
                detail: L10n.text("ui.slash_command_plan_detail"),
                systemImage: "list.clipboard",
                isCurrent: composerState.isPlanModeSelected
            ))
        }
        if let session = sessionStore.selectedSession, sessionStore.supportsCodexThreadManagement(session) {
            commands.append(ComposerSlashCommand(
                action: .compact,
                name: "compact",
                title: L10n.text("ui.compression_context"),
                detail: L10n.text("ui.slash_command_compact_detail"),
                systemImage: "arrow.down.right.and.arrow.up.left",
                unavailableReason: session.isRunning
                    ? L10n.text("ui.please_wait_for_the_current_turn_to_complete")
                    : nil
            ))
        }
        return commands
    }

    func moveAutocompleteSelection(by offset: Int) {
        let count = autocompleteSuggestions.count
        guard count > 0 else { return }
        selectedSkillSuggestionIndex = (selectedSkillSuggestionIndex + offset + count) % count
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func commitAutocompleteSelection() {
        let suggestions = autocompleteSuggestions
        guard !suggestions.isEmpty else { return }
        selectAutocompleteSuggestion(suggestions[min(selectedSkillSuggestionIndex, suggestions.count - 1)])
    }

    func selectAutocompleteSuggestion(_ suggestion: ComposerAutocompleteSuggestion) {
        switch suggestion {
        case .skill(let skill):
            selectSkillFromAutocomplete(skill)
        case .command(let command):
            // 暂不可用的命令保留草稿和浮层，原因已经显示在行内。
            guard command.unavailableReason == nil else { return }
            removeAutocompleteToken()
            performSlashCommand(command.action)
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    func selectSkillFromAutocomplete(_ skill: SkillCapability) {
        guard removeAutocompleteToken() else { return }
        addSkillAttachment(skill, closesPanel: false)
    }

    /// 从正文移除触发词并关闭浮层；其余正文、附件和焦点保持不变。
    @discardableResult
    func removeAutocompleteToken() -> Bool {
        guard let query = activeSkillQuery else { return false }
        if let updatedText = composerTextSubmitBridge.replaceText(in: query.replacementRange, with: "") {
            composerState.draft = updatedText
        }
        activeSkillQuery = nil
        selectedSkillSuggestionIndex = 0
        return true
    }

    func performSlashCommand(_ action: ComposerSlashCommandAction) {
        switch action {
        case .model:
            // 等本轮文本替换和浮层收起提交后再弹出，避免在同一视图更新里切换呈现状态。
            DispatchQueue.main.async {
                showsModelGridPicker = true
            }
        case .permission(let mode):
            setPermissionMode(mode)
        case .plan:
            setSendMode(.plan)
        case .compact:
            guard let session = sessionStore.selectedSession else { return }
            // 执行时 SessionStore 会再次检查运行态与通道，浮层打开时的判断不作数。
            Task { await sessionStore.compactSessionContext(session) }
        }
    }
}

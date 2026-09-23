import SwiftUI

/// 工作区角色图标选择与 emoji 选择共用同一弹层尺寸和交互语义，
/// 从根页面拆出后仍只依赖现有外观 Store，不引入新的状态层。
struct WorkspaceCharacterPicker: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let project: AgentProject
    let profileID: String
    @ObservedObject var appearanceStore: WorkspaceAppearanceStore
    let style: WorkspaceIconStyle
    let currentCharacterID: String
    let unavailableCharacterIDs: Set<String>
    let tokens: ThemeTokens

    private let columns = Array(repeating: GridItem(.fixed(52), spacing: 8), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("ui.workspace_icon"))
                    .font(themeStore.uiFont(.headline, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Text(project.name)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(WorkspaceAppearanceStore.characters(for: style)) { character in
                    let isUnavailable = unavailableCharacterIDs.contains(character.id)
                    Button {
                        appearanceStore.setCustomCharacterID(
                            character.id,
                            style: style,
                            profileID: profileID,
                            projectID: project.id
                        )
                        dismiss()
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(character.assetName)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 52, height: 52)
                                .clipShape(WorkspaceIconMeeGoShape())
                                .overlay {
                                    WorkspaceIconMeeGoShape()
                                        .stroke(tokens.border.opacity(0.5), lineWidth: 0.75)
                                }
                            if currentCharacterID == character.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(themeStore.uiFont(size: 12, weight: .semibold))
                                    .foregroundStyle(tokens.primaryAction)
                                    .background(tokens.surface, in: Circle())
                            }
                        }
                    }
                    .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
                    .disabled(isUnavailable)
                    .opacity(isUnavailable ? 0.36 : 1)
                    .accessibilityIdentifier("workspace.character.\(character.id)")
                    .accessibilityLabel(character.name)
                    .accessibilityAddTraits(currentCharacterID == character.id ? .isSelected : [])
                }
            }

            Button {
                appearanceStore.setCustomCharacterID(nil, profileID: profileID, projectID: project.id)
                dismiss()
            } label: {
                Label(L10n.text("ui.restore_default_appearance"), systemImage: "arrow.counterclockwise")
            }
            .font(themeStore.uiFont(.callout, weight: .medium))
            .disabled(
                appearanceStore.customCharacterID(profileID: profileID, projectID: project.id) == nil
            )
        }
        .padding(18)
        .frame(width: 336)
        .background(tokens.surface)
        .accessibilityIdentifier("workspace.characterPicker")
    }
}

struct WorkspaceEmojiPicker: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let project: AgentProject
    let profileID: String
    @ObservedObject var appearanceStore: WorkspaceAppearanceStore
    let currentEmoji: String
    let unavailableEmoji: Set<String>
    let tokens: ThemeTokens
    @State private var customInput = ""
    @State private var validationMessage: String?

    private let columns = Array(repeating: GridItem(.fixed(44), spacing: 8), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("ui.workspace_icon"))
                    .font(themeStore.uiFont(.headline, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Text(project.name)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(WorkspaceAppearanceStore.builtInEmoji, id: \.self) { emoji in
                    let isUnavailable = unavailableEmoji.contains(emoji)
                    Button {
                        appearanceStore.setCustomEmoji(
                            emoji,
                            profileID: profileID,
                            projectID: project.id
                        )
                        dismiss()
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Text(emoji)
                                .font(.system(size: 26))
                                .frame(width: 44, height: 44)
                                .background(
                                    tokens.elevatedSurface.opacity(0.68),
                                    in: WorkspaceIconMeeGoShape()
                                )
                            if currentEmoji == emoji {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(themeStore.uiFont(size: 12, weight: .semibold))
                                    .foregroundStyle(tokens.primaryAction)
                                    .background(tokens.surface, in: Circle())
                            }
                        }
                    }
                    .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
                    .disabled(isUnavailable)
                    .opacity(isUnavailable ? 0.36 : 1)
                    .accessibilityLabel(emoji)
                    .accessibilityAddTraits(currentEmoji == emoji ? .isSelected : [])
                }
            }

            Divider()
                .overlay(tokens.border.opacity(0.6))

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("ui.custom_emoji"))
                    .font(themeStore.uiFont(.subheadline, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)

                HStack(spacing: 8) {
                    TextField(L10n.text("ui.enter_one_emoji"), text: $customInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 24))
                        .submitLabel(.done)
                        .onSubmit(applyCustomEmoji)

                    Button(L10n.text("ui.apply"), action: applyCustomEmoji)
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(tokens.primaryActionForeground)
                        .tint(tokens.primaryAction)
                        .disabled(customInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let validationMessage {
                    Text(validationMessage)
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(tokens.warning)
                }
            }

            Button {
                appearanceStore.setCustomEmoji(nil, profileID: profileID, projectID: project.id)
                dismiss()
            } label: {
                Label(L10n.text("ui.restore_default_appearance"), systemImage: "arrow.counterclockwise")
            }
            .font(themeStore.uiFont(.callout, weight: .medium))
            .disabled(appearanceStore.customEmoji(profileID: profileID, projectID: project.id) == nil)
        }
        .padding(18)
        .frame(width: 336)
        .background(tokens.surface)
        .accessibilityIdentifier("workspace.emojiPicker")
        .onAppear {
            customInput = appearanceStore.customEmoji(
                profileID: profileID,
                projectID: project.id
            ) ?? ""
        }
    }

    private func applyCustomEmoji() {
        guard let emoji = WorkspaceAppearanceStore.normalizedEmoji(customInput) else {
            validationMessage = L10n.text("ui.enter_one_valid_emoji")
            return
        }
        guard !unavailableEmoji.contains(emoji) else {
            validationMessage = L10n.text("ui.emoji_already_used")
            return
        }
        appearanceStore.setCustomEmoji(emoji, profileID: profileID, projectID: project.id)
        dismiss()
    }
}

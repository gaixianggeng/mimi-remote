import SwiftUI

/// 权限入口分别展示服务端报告的当前权限，以及本地将在下一轮发送的选择。
struct ComposerPermissionMenu: View {
    let permissionModes: [ComposerPermissionMode]
    let permissionProfiles: [CodexAppServerPermissionProfileSummary]
    let selectedMode: ComposerPermissionMode
    let selectedProfileID: String?
    let activeProfileID: String?
    let preservesThreadPermissionSettings: Bool
    let permissionAccessibilityValue: String
    let tint: Color
    let reduceMotion: Bool
    let usesPhoneStyle: Bool
    let onSelectMode: (ComposerPermissionMode) -> Void
    let onSelectProfile: (CodexAppServerPermissionProfileSummary) -> Void

    var body: some View {
        Menu {
            Section(L10n.text("ui.permission_mode")) {
                ForEach(permissionModes) { mode in
                    Button {
                        onSelectMode(mode)
                    } label: {
                        Label(mode.title, systemImage: modeIcon(mode))
                    }
                    .accessibilityHint(mode.detail)
                }
            }
            if !permissionProfiles.isEmpty {
                Section(L10n.text("ui.advanced_permission_profiles")) {
                    ForEach(permissionProfiles) { profile in
                        Button {
                            onSelectProfile(profile)
                        } label: {
                            Label(profile.id, systemImage: profileIcon(profile))
                        }
                        .accessibilityHint(profile.description ?? L10n.text("ui.use_named_permission_profile"))
                    }
                }
            }
            Section(L10n.text("ui.permission_status")) {
                if let activeProfileID {
                    Text(L10n.format("ui.session_permission_settings_value", activeProfileID))
                }
                if preservesThreadPermissionSettings {
                    Text(L10n.text("ui.follow_the_current_thread_permissions"))
                } else {
                    Text(L10n.format("ui.next_turn_permission_value", selectedPermissionName))
                }
            }
        } label: {
            ComposerToolbarControlLabel(
                title: labelTitle,
                systemImage: labelSystemImage,
                trailingSystemImage: nil,
                isSelected: false,
                tint: tint,
                titleMaxWidth: nil,
                accessibilityLabel: L10n.text("ui.permission_mode"),
                usesPhoneStyle: usesPhoneStyle,
                usesCondensedTitle: false
            )
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(L10n.text("ui.permission_mode"))
        .accessibilityValue(permissionAccessibilityValue)
    }

    private func modeIcon(_ mode: ComposerPermissionMode) -> String {
        !preservesThreadPermissionSettings && selectedProfileID == nil && selectedMode == mode
            ? "checkmark"
            : mode.systemImage
    }

    private func profileIcon(_ profile: CodexAppServerPermissionProfileSummary) -> String {
        !preservesThreadPermissionSettings && selectedProfileID == profile.id
            ? "checkmark"
            : "shield.lefthalf.filled"
    }

    private var selectedPermissionName: String {
        selectedProfileID.map { displayName(for: $0) } ?? selectedMode.title
    }

    private var labelTitle: String {
        switch ComposerPermissionMenuLabel.resolve(
            preservesThreadSettings: preservesThreadPermissionSettings,
            selectedMode: selectedMode,
            selectedProfileID: selectedProfileID,
            activeProfileID: activeProfileID
        ) {
        case .inherited: L10n.text("ui.follow_the_current_thread_permissions")
        case .sessionProfile(let id): id
        case .nextMode(let mode): L10n.format("ui.next_turn_permission_value", mode.title)
        case .nextProfile(let id): L10n.format("ui.next_turn_permission_value", displayName(for: id))
        }
    }

    private var labelSystemImage: String {
        if preservesThreadPermissionSettings {
            guard let activeProfileID else { return "lock.shield" }
            return ComposerPermissionMode(builtInPermissionProfileID: activeProfileID)?.systemImage
                ?? "shield.lefthalf.filled"
        }
        return selectedProfileID == nil ? selectedMode.systemImage : "shield.lefthalf.filled"
    }

    private func displayName(for profileID: String) -> String {
        ComposerPermissionMode(builtInPermissionProfileID: profileID)?.title ?? profileID
    }
}

enum ComposerPermissionMenuLabel: Equatable {
    case inherited
    case sessionProfile(String)
    case nextMode(ComposerPermissionMode)
    case nextProfile(String)

    static func resolve(
        preservesThreadSettings: Bool,
        selectedMode: ComposerPermissionMode,
        selectedProfileID: String?,
        activeProfileID: String?
    ) -> Self {
        if preservesThreadSettings {
            return activeProfileID.map(Self.sessionProfile) ?? .inherited
        }
        return selectedProfileID.map(Self.nextProfile) ?? .nextMode(selectedMode)
    }
}

import AppKit
import Foundation

struct SystemPrivacySettingsClient {
    var openFullDiskAccessSettings: @MainActor () -> Void
}

extension SystemPrivacySettingsClient {
    static let live = SystemPrivacySettingsClient(
        openFullDiskAccessSettings: {
            guard let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
            ) else { return }
            NSWorkspace.shared.open(url)
        }
    )

    static let noop = SystemPrivacySettingsClient(openFullDiskAccessSettings: {})
}

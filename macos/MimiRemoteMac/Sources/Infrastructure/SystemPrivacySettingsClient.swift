import AppKit
import Foundation
import Photos

/// “照片”图库权限只能由带 Info.plist 的 App 申请。LaunchAgent 通过主 App 的 supervisor
/// 启动 agentd 后，这里授予的权限会沿责任链覆盖 agentd 读取照片图库的请求。
enum PhotosAccessState: Equatable, Sendable {
    case notDetermined
    case authorized
    case limited
    case denied
    case restricted

    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized: self = .authorized
        case .limited: self = .limited
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .notDetermined: self = .notDetermined
        @unknown default: self = .notDetermined
        }
    }

    var title: String {
        switch self {
        case .notDetermined: "尚未请求"
        case .authorized: "已允许"
        case .limited: "仅部分照片"
        case .denied: "已拒绝"
        case .restricted: "受系统限制"
        }
    }
}

struct SystemPrivacySettingsClient {
    var openFullDiskAccessSettings: @MainActor () -> Void
    var photosAccessState: @MainActor () -> PhotosAccessState
    var requestPhotosAccess: @MainActor () async -> PhotosAccessState
    var openPhotosPrivacySettings: @MainActor () -> Void
}

extension SystemPrivacySettingsClient {
    static let live = SystemPrivacySettingsClient(
        openFullDiskAccessSettings: {
            openPrivacyPane("Privacy_AllFiles")
        },
        photosAccessState: {
            PhotosAccessState(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        },
        requestPhotosAccess: {
            // 菜单栏 App 没有 Dock 图标；先把自己带到前台，系统授权框才不会被其他窗口挡住。
            NSApplication.shared.activate(ignoringOtherApps: true)
            return PhotosAccessState(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
        },
        openPhotosPrivacySettings: {
            openPrivacyPane("Privacy_Photos")
        }
    )

    static let noop = SystemPrivacySettingsClient(
        openFullDiskAccessSettings: {},
        photosAccessState: { .notDetermined },
        requestPhotosAccess: { .notDetermined },
        openPhotosPrivacySettings: {}
    )

    @MainActor
    private static func openPrivacyPane(_ anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

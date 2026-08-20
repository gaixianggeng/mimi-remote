import AppKit
import Foundation
import Photos

enum PhotoLibraryAuthorization: Equatable, Sendable {
    case notDetermined
    case authorized
    case limited
    case denied
    case restricted

    var title: String {
        switch self {
        case .notDetermined: "尚未询问"
        case .authorized: "已允许"
        case .limited: "已允许部分照片"
        case .denied: "已拒绝"
        case .restricted: "受系统限制"
        }
    }
}

struct PhotoLibraryAccessClient {
    var authorizationStatus: @MainActor () -> PhotoLibraryAuthorization
    var requestAuthorization: @MainActor () async -> PhotoLibraryAuthorization
    var openPhotosPrivacySettings: @MainActor () -> Void
    var openFullDiskAccessSettings: @MainActor () -> Void
}

extension PhotoLibraryAccessClient {
    @MainActor
    static var live: PhotoLibraryAccessClient {
        PhotoLibraryAccessClient(
            authorizationStatus: {
                map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
            },
            requestAuthorization: {
                await withCheckedContinuation { continuation in
                    PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                        continuation.resume(returning: map(status))
                    }
                }
            },
            openPhotosPrivacySettings: {
                openSystemSettingsPane("Privacy_Photos")
            },
            openFullDiskAccessSettings: {
                openSystemSettingsPane("Privacy_AllFiles")
            }
        )
    }

    static let noop = PhotoLibraryAccessClient(
        authorizationStatus: { .authorized },
        requestAuthorization: { .authorized },
        openPhotosPrivacySettings: {},
        openFullDiskAccessSettings: {}
    )

    private static func map(_ status: PHAuthorizationStatus) -> PhotoLibraryAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        case .limited: .limited
        @unknown default: .restricted
        }
    }

    @MainActor
    private static func openSystemSettingsPane(_ pane: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

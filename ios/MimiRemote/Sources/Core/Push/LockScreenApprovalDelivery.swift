import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 一次锁屏交互。decision 为空表示用户点了通知本身，也就是「查看详情」。
struct LockScreenApprovalDelivery: Equatable, Identifiable {
    let notification: LockScreenApprovalNotification
    let decision: LockScreenApprovalDecision?
    /// 系统回调给出的真实 UNNotificationRequest.identifier。
    /// 静默推送没有这个回调值，Store 会从 deliveredNotifications() 反查。
    let requestIdentifier: String?

	var id: String {
		notification.approvalIdentifier + "|" + (decision?.rawValue ?? "open")
	}

	init?(
		userInfo: [AnyHashable: Any],
		actionIdentifier: String,
		requestIdentifier: String? = nil
	) {
		guard let notification = LockScreenApprovalNotification(userInfo: userInfo) else {
			return nil
		}
		self.notification = notification
		self.decision = notification.event == .pending && notification.kind.isActionableFromLockScreen
			? LockScreenApprovalCategory.decision(forActionIdentifier: actionIdentifier)
			: nil
		self.requestIdentifier = requestIdentifier
	}
}

/// 系统回调只负责严格解码并入队，真正的网络动作在视图层执行。静默推送只等待
/// 本地通知清理完成，不等待网络请求。
@MainActor
final class LockScreenApprovalInbox: ObservableObject {
    @Published private(set) var pending: LockScreenApprovalDelivery?

	@discardableResult
	func receive(
		userInfo: [AnyHashable: Any],
		actionIdentifier: String,
		requestIdentifier: String? = nil
	) -> Bool {
		guard let delivery = LockScreenApprovalDelivery(
			userInfo: userInfo,
			actionIdentifier: actionIdentifier,
			requestIdentifier: requestIdentifier
		) else {
			return false
		}
		pending = delivery
		return true
    }

    func consume(_ delivery: LockScreenApprovalDelivery) {
        guard pending == delivery else { return }
        pending = nil
    }
}

/// Device Token 只在 UIApplicationDelegate 回调里出现，而 SwiftUI App 本身拿不到
/// 这些回调。这个桥接把它们转交给 Store，同时保证 App 不持有 delegate 生命周期。
@MainActor
enum PushDeviceTokenBridge {
	static var onToken: ((Data) -> Void)?
	static var onFailure: ((Error) -> Void)?
	/// 静默的「已处理」推送不会经过通知点击回调，只能在这里拿到。
	static var onSilentPayload: (([AnyHashable: Any]) async -> Void)?
}

#if canImport(UIKit)
final class PushApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            PushDeviceTokenBridge.onToken?(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            PushDeviceTokenBridge.onFailure?(error)
        }
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            // 系统只有在这个 completion 返回后才会认为后台清理完成；必须等待
            // Store 反查并删除真实 delivered request，而不是 fire-and-forget。
            await PushDeviceTokenBridge.onSilentPayload?(userInfo)
            completionHandler(.noData)
        }
    }
}
#endif

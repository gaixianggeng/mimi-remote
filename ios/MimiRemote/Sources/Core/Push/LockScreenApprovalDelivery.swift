import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 一次锁屏交互。decision 为空表示用户点了通知本身，也就是「查看详情」。
struct LockScreenApprovalDelivery: Equatable, Identifiable {
    let notification: LockScreenApprovalNotification
    let decision: LockScreenApprovalDecision?

	var id: String {
        notification.actionID + "|" + (decision?.rawValue ?? "open")
	}

	init?(userInfo: [AnyHashable: Any], actionIdentifier: String) {
		guard let notification = LockScreenApprovalNotification(userInfo: userInfo) else {
			return nil
		}
		self.notification = notification
		self.decision = notification.event == .pending
			? LockScreenApprovalCategory.decision(forActionIdentifier: actionIdentifier)
			: nil
	}
}

/// 系统回调只负责严格解码并入队，真正的网络动作在视图层执行——这与既有的会话
/// 通知路由保持同一套结构：回调不等待网络，避免通知处理超时被系统终止。
@MainActor
final class LockScreenApprovalInbox: ObservableObject {
    @Published private(set) var pending: LockScreenApprovalDelivery?

    @discardableResult
    func receive(userInfo: [AnyHashable: Any], actionIdentifier: String) -> Bool {
		guard let delivery = LockScreenApprovalDelivery(
			userInfo: userInfo,
			actionIdentifier: actionIdentifier
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
    static var onSilentPayload: (([AnyHashable: Any]) -> Void)?
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
            PushDeviceTokenBridge.onSilentPayload?(userInfo)
            completionHandler(.noData)
        }
    }
}
#endif

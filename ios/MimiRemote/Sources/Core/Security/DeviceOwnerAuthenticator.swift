import Foundation
import LocalAuthentication

enum DeviceOwnerAuthenticationResult: Equatable {
    case authenticated
    /// 设备没有设置锁屏密码，系统没有可用的验证手段。
    case notConfigured
    case cancelled
    case failed
}

protocol DeviceOwnerAuthenticating {
    func authenticate(reason: String) async -> DeviceOwnerAuthenticationResult
}

struct SystemDeviceOwnerAuthenticator: DeviceOwnerAuthenticating {
    func authenticate(reason: String) async -> DeviceOwnerAuthenticationResult {
        let context = LAContext()
        var error: NSError?
        // deviceOwnerAuthentication 在面容或指纹失败后可以改用设备密码，机主不会被锁在外面。
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return error?.code == LAError.Code.passcodeNotSet.rawValue ? .notConfigured : .failed
        }
        do {
            let passed = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return passed ? .authenticated : .failed
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            return .cancelled
        } catch {
            return .failed
        }
    }
}

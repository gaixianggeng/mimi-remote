import Foundation

// 首次连接一台电脑的预热窗口。冷启动要先建隧道、再等 agentd 网关的上游就绪，
// 窗口内的失败仍会自动重试，是过程而不是给用户的结论。
extension SessionStore {
    /// 未配置连接时不开窗，返回的无效令牌释放起来同样无副作用。
    static let invalidConnectionWarmUpToken = 0

    /// 界面唯一应当依赖的“正在建立连接”判断。
    ///
    /// 终态优先于预热：凭据失效、连接终止和设备本身没有网络都是明确结论，
    /// 继续播放连接过渡只会把用户困在一个永远不会好的动画里。
    var isEstablishingConnection: Bool {
        guard isConnectionWarmUpActive || isConnectionSwitchInProgress else {
            return false
        }
        guard connectionTermination == nil,
              !appStore.requiresRePairing,
              !isNetworkUnavailable else {
            return false
        }
        return true
    }

    /// 取得一份预热窗口持有权，返回用于释放的令牌。
    ///
    /// 冷启动会有多个嵌套且并发的持有者：RootView 的启动任务、bootstrap，以及一到多个
    /// 退避重试循环。用集合而不是“最新一个令牌”，先结束的持有者不会提前关掉别人还开着
    /// 的窗口；窗口只在最后一个持有者退出时关闭。
    @discardableResult
    func beginConnectionWarmUp() -> Int {
        guard appStore.isConfigured else {
            return Self.invalidConnectionWarmUpToken
        }
        nextConnectionWarmUpToken += 1
        let token = nextConnectionWarmUpToken
        liveConnectionWarmUpTokens.insert(token)
        isConnectionWarmUpActive = true
        return token
    }

    /// 释放一份持有权。仍有其他持有者时窗口保持打开，重复释放同一令牌无副作用。
    func endConnectionWarmUp(_ token: Int) {
        guard liveConnectionWarmUpTokens.remove(token) != nil else {
            return
        }
        isConnectionWarmUpActive = !liveConnectionWarmUpTokens.isEmpty
    }
}

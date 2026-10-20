import Foundation

// 「默认模型」页一次列出所有 Runtime，和只补当前会话 Runtime 的输入框菜单不同（#871）。
extension SessionStore {
    /// 目录里还没有该 Runtime 的条目，或只剩上一轮沿用、尚未确认的旧条目。
    func modelCatalogIsMissing(runtimeProvider: String) -> Bool {
        let provider = Self.normalizedRuntimeProvider(runtimeProvider)
        return retainedModelCatalogProviders.contains(provider)
            || !appServerModelOptions.contains { Self.normalizedRuntimeProvider($0.runtimeProvider) == provider }
    }

    /// 进页、目录被换连接清空或用户点刷新时调用。启动时那次聚合刷新可能在连接就绪前失败，
    /// 失败同样记 5 分钟负缓存；负缓存是为了发送路径不重复请求，用户正看着这一页时，
    /// 缺目录的 Runtime 要越过它定向补拉，否则会一直停在「型号未确认」直到退出重进。
    func refreshDefaultModelCatalog(runtimeProviders: [String], force: Bool) async {
        let hostScope = appStore.activeHostScope
        // 设置页根层或发送路径可能正有一次聚合刷新在途：这里的刷新会被它去重直接跳过；
        // 它失败时还会改写各 Runtime 的补拉时间，让并发发出的定向结果被当成过期丢掉。
        // 先等它收尾，再按结果判断还缺谁。
        if isRefreshingAppServerModels {
            for await isRefreshing in $isRefreshingAppServerModels.values where !isRefreshing {
                break
            }
        }
        guard !Task.isCancelled, appStore.activeHostScope == hostScope else { return }
        await refreshAppServerModelOptions(force: force, expectedHostScope: hostScope)
        for provider in runtimeProviders where modelCatalogIsMissing(runtimeProvider: provider) {
            guard appStore.activeHostScope == hostScope else { return }
            turnModelRefreshByRuntime.removeValue(forKey: Self.normalizedRuntimeProvider(provider))
            await prepareTurnModelOptions(runtimeProvider: provider, hostScope: hostScope)
        }
    }
}

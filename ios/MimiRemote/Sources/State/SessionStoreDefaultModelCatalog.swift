import Foundation

// 用户正看着模型选择的地方：「默认模型」页一次列出所有 Runtime（#871），输入框只补当前会话的
// Runtime（#1000）。发送路径仍走 prepareTurnModelOptions 并遵守负缓存。
extension SessionStore {
    /// 目录里还没有该 Runtime 的条目，或只剩上一轮沿用、尚未确认的旧条目。
    func modelCatalogIsMissing(runtimeProvider: String) -> Bool {
        let provider = Self.normalizedRuntimeProvider(runtimeProvider)
        return retainedModelCatalogProviders.contains(provider)
            || !appServerModelOptions.contains { Self.normalizedRuntimeProvider($0.runtimeProvider) == provider }
    }

    /// 进「默认模型」页、输入框准备、目录被换连接清空或用户点刷新时调用。冷启动或回前台时，
    /// 第一次聚合刷新常常早于 Tailcat 隧道就绪而失败，失败同样记 5 分钟负缓存；负缓存是为了
    /// 发送路径不重复请求，用户正看着模型时，缺目录的 Runtime 要越过它定向补拉，否则菜单会
    /// 一直停在内置兜底，直到手动「刷新模型列表」。
    func refreshPickerModelCatalog(runtimeProviders: [String], force: Bool) async {
        let hostScope = appStore.activeHostScope
        await waitForInFlightAggregateModelRefresh()
        guard !Task.isCancelled, appStore.activeHostScope == hostScope else { return }
        await refreshAppServerModelOptions(force: force, expectedHostScope: hostScope)
        await refetchMissingModelCatalogs(runtimeProviders: runtimeProviders, hostScope: hostScope)
    }

    /// 打开模型菜单时只补缺口，不重新做聚合刷新：输入框准备那次也可能赶在连接就绪前失败。
    func refetchMissingModelCatalogs(runtimeProviders: [String]) async {
        let hostScope = appStore.activeHostScope
        await waitForInFlightAggregateModelRefresh()
        guard !Task.isCancelled, appStore.activeHostScope == hostScope else { return }
        await refetchMissingModelCatalogs(runtimeProviders: runtimeProviders, hostScope: hostScope)
    }

    private func refetchMissingModelCatalogs(runtimeProviders: [String], hostScope: HostScope) async {
        for provider in runtimeProviders where modelCatalogIsMissing(runtimeProvider: provider) {
            guard !Task.isCancelled, appStore.activeHostScope == hostScope else { return }
            turnModelRefreshByRuntime.removeValue(forKey: Self.normalizedRuntimeProvider(provider))
            await prepareTurnModelOptions(runtimeProvider: provider, hostScope: hostScope)
        }
    }

    /// 设置页根层、工作区页或发送路径可能正有一次聚合刷新在途：新的刷新会被它去重直接跳过；
    /// 它失败时还会改写各 Runtime 的补拉时间，让并发发出的定向结果被当成过期丢掉。先等它收尾。
    private func waitForInFlightAggregateModelRefresh() async {
        guard isRefreshingAppServerModels else { return }
        for await isRefreshing in $isRefreshingAppServerModels.values where !isRefreshing {
            break
        }
    }
}

import Combine

/// 设置详情页共享的内存偏好。导航外壳可复用同一实例，因此旋转不会重置尚未持久化的选择。
final class SettingsTransientPreferences: ObservableObject {
    @Published var hostInstallationPlatform: HostInstallationPlatform = .mac
    /// nil = 用户还没表态，按调用方给的默认值显示；一旦手动展开或收起就固定下来。
    /// 不在 onAppear 里播种默认值：那发生在首次布局之后，会让依赖内容高度的居中
    /// 多等一轮，快照只跑两个 layout pass 就会录到没收敛的中间态。
    @Published var hostInstallationExpansionOverride: Bool?
    /// 「发送下载链接」的分享面板由连接分组的 Section 统一呈现（见 connectionPresentationSection）。
    /// 这一行里的 `ShareLink` 点了没有任何反应也没有日志（iOS 26.5 / 27.0 模拟器和 iOS 27 真机
    /// 都复现，#424），原因没有定位；改为行里登记请求、Section 级显式呈现。
    @Published var hostInstallerShareRequest: HostInstallerShareRequest?
    @Published var speedTestRoute: ConnectionTestRoute = .tailscale
    @Published var didSelectInitialSpeedTestRoute = false
    @Published var recordsBenchmarkSamples = false
    @Published var benchmarkScenario: ConnectionBenchmarkScenario = .warm
}

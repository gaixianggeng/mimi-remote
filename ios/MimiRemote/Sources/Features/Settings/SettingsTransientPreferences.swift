import Combine

/// 设置详情页共享的内存偏好。导航外壳可复用同一实例，因此旋转不会重置尚未持久化的选择。
final class SettingsTransientPreferences: ObservableObject {
    @Published var hostInstallationPlatform: HostInstallationPlatform = .mac
    @Published var isHostInstallationExpanded = false
    @Published var speedTestRoute: ConnectionTestRoute = .tailscale
    @Published var didSelectInitialSpeedTestRoute = false
    @Published var recordsBenchmarkSamples = false
    @Published var benchmarkScenario: ConnectionBenchmarkScenario = .warm
}

import Foundation

/// 原生 Harness 通道的受控开关。
///
/// **默认关闭，而且生产不提供打开它的路径。** 关着的时候 `AppStore` 不注入
/// `harnessFactory`，`AppServerRuntimeBundle.harness` 保持 `nil`：deepseek 只由原生
/// 通道承接，此时原生未注入，相关调用显式失败，不会回退到任何 app-server actor。
///
/// 为什么是一个显式值而不是环境变量或配置项：H11 的卡片要求"识别到 native-v1 描述后
/// 才选原生"，也就是**打开这件事本身要有一次决策**。做成隐式开关（读环境、读 UserDefaults）
/// 会让"现在到底跑的是哪条协议"变成一个要靠运行时调查才能回答的问题。这里让它只能被
/// 显式传入，于是"谁打开了它"在调用点一眼可见。
///
/// 本类型只提供注入点，不自行开启；打开它属于 H11。
struct HarnessNativeRollout: Equatable {
    /// 原生客户端是否承接 deepseek。关闭时不注入 factory。
    var isEnabled: Bool

    /// 生产默认。AppStore 以此为初值，且没有任何代码路径把它改成 enabled。
    static let disabled = HarnessNativeRollout(isEnabled: false)
}

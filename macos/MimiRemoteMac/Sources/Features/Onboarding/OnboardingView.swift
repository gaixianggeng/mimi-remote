import SwiftUI

struct OnboardingView: View {
    /// 与 iOS 首次连接引导、README「Get started」第一步同一链接，供菜单栏详情复用。
    static let codexSetupURL = OnboardingFixURL.codex.url

    let store: HostStore
    @State private var onboardingStore: OnboardingStore?

    var body: some View {
        Group {
            if let onboardingStore {
                OnboardingFlowView(store: onboardingStore)
            } else {
                ProgressView("正在准备首次设置…")
                    .frame(maxWidth: .infinity, minHeight: 220)
            }
        }
        .onAppear {
            if onboardingStore == nil {
                onboardingStore = store.onboardingWizard()
            }
        }
    }
}

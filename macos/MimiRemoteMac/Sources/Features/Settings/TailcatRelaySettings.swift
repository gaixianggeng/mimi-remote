import AppKit
import Foundation
import SwiftUI

enum TailcatRelayMode: String, CaseIterable, Identifiable {
    case tailcatDefault
    case custom
    case mimi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tailcatDefault: "默认 Tailcat 自带"
        case .custom: "自建中转"
        case .mimi: "Mimi 中转"
        }
    }
}

/// 中转服务是一个单选，选中即生效：不再有「选中 → 使用此中转」两步，也不把重置、生成二维码混进来。
/// 只有会影响正在使用的手机时才确认一次；只有自建地址需要多填一步。
struct TailcatRelayPicker: View {
    let store: HostStore
    /// 配对窗口里说明文字放在二维码上方，这里只留控件和结果。
    var showsCaption = true
    @Binding var isApplying: Bool
    /// 更换成功后的下一步由宿主决定：配对窗口就地刷新二维码，设置页打开配对窗口。
    let onApplied: () async -> Void

    @State private var pendingMode: TailcatRelayMode?
    @State private var isEditingCustomURL = false
    @State private var customDERPMapURL = ""

    var body: some View {
        if showsCaption {
            picker
            Text(TailcatRelayPresentation.caption(mode: currentMode, derpMapURL: store.tailcatDERPMapURL))
                .font(.caption).foregroundStyle(.secondary)
            changeAddressButton
            statusLine
        } else {
            // 配对窗口里和连接方式共用一行高度，控件并排，切换选项时二维码不会被顶下去。
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    picker
                        .fixedSize()
                    changeAddressButton
                }
                statusLine
            }
        }
    }

    private var picker: some View {
        Picker("中转服务", selection: selection) {
            ForEach(TailcatRelayMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.menu)
        .disabled(!store.canChangeTailcat || isApplying)
        .task {
            // 手机也能切换电脑线路；只在控件可见时刷新，页面离开后由 SwiftUI 取消。
            while !Task.isCancelled {
                await store.refreshTailcatStatus()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .confirmationDialog(
            "更换中转服务？",
            isPresented: Binding(get: { pendingMode != nil }, set: { if !$0 { pendingMode = nil } }),
            titleVisibility: .visible,
            presenting: pendingMode
        ) { mode in
            Button("更换并重新配对") { apply(mode, url: mode == .custom ? trimmedCustomURL : "") }
        } message: { _ in
            Text("本机的内置连接会短暂重连，使用该线路的手机可能需要重新扫码。Tailscale 和局域网连接不受影响。")
        }
        .sheet(isPresented: $isEditingCustomURL) { customRelaySheet }
    }

    @ViewBuilder
    private var changeAddressButton: some View {
        if currentMode == .custom {
            Button("更改地址…") { editCustomURL() }
                .disabled(!store.canChangeTailcat || isApplying)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if isApplying || store.isUpdatingTailcat {
            ProgressView().controlSize(.small)
        } else if let error = store.tailcatError {
            Text(error).font(.caption).foregroundStyle(.red)
        } else if showsCaption, let notice = store.tailcatNotice {
            Text(notice).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var selection: Binding<TailcatRelayMode> {
        // 始终读实际配置：取消确认或更换失败时，控件要回到真实状态，不能停在没生效的选项上。
        Binding(get: { currentMode }, set: { choose($0) })
    }

    private var currentMode: TailcatRelayMode {
        TailcatRelayPresentation.mode(isManaged: store.tailcatIsManaged, derpMapURL: store.tailcatDERPMapURL)
    }

    private var trimmedCustomURL: String {
        customDERPMapURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func choose(_ mode: TailcatRelayMode) {
        guard mode != currentMode else { return }
        if mode == .custom {
            editCustomURL()
        } else {
            requestApply(mode, url: "")
        }
    }

    private func editCustomURL() {
        customDERPMapURL = store.tailcatIsManaged ? "" : store.tailcatDERPMapURL
        isEditingCustomURL = true
    }

    private func requestApply(_ mode: TailcatRelayMode, url: String) {
        if TailcatRelayPresentation.needsReconnectionConfirmation(
            mode: mode, url: url, tailcatEnabled: store.tailcatEnabled,
            isManaged: store.tailcatIsManaged, currentURL: store.tailcatDERPMapURL
        ) {
            pendingMode = mode
        } else {
            apply(mode, url: url)
        }
    }

    private func apply(_ mode: TailcatRelayMode, url: String) {
        guard !isApplying else { return }
        isApplying = true
        Task {
            defer { isApplying = false }
            let choice = mode == .tailcatDefault ? "default" : mode.rawValue
            await store.setTailcatRelay(choice, url: url)
            guard store.tailcatError == nil, store.tailcatEnabled else { return }
            await onApplied()
        }
    }

    private var customRelaySheet: some View {
        let validation = TailcatRelayPresentation.customURLValidationMessage(trimmedCustomURL)
        return VStack(alignment: .leading, spacing: 12) {
            Text("自建中转").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(TailcatRelayPresentation.selfHostedSteps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step)")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.callout).foregroundStyle(.secondary)
            Link("查看部署文档", destination: TailcatRelayPresentation.selfHostedGuideURL)
                .font(.callout)
            TextField("DERP Map 地址，例如 https://relay.example.com/derpmap.json", text: $customDERPMapURL)
                .textFieldStyle(.roundedBorder)
                .environment(\.layoutDirection, .leftToRight)
            if !trimmedCustomURL.isEmpty, let validation {
                Text(validation).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { isEditingCustomURL = false }
                    .keyboardShortcut(.cancelAction)
                Button("使用此地址") {
                    isEditingCustomURL = false
                    requestApply(.custom, url: trimmedCustomURL)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(validation != nil || trimmedCustomURL == store.tailcatDERPMapURL)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// 三种中转的判定和文案。视图只负责呈现，规则可以直接测试。
enum TailcatRelayPresentation {
    static func mode(isManaged: Bool, derpMapURL: String) -> TailcatRelayMode {
        if isManaged { return .mimi }
        return derpMapURL.isEmpty ? .tailcatDefault : .custom
    }

    static func caption(mode: TailcatRelayMode, derpMapURL: String) -> String {
        switch mode {
        case .tailcatDefault:
            "免费，无需配置。只在手机无法直连电脑时使用。"
        case .custom:
            if let host = URLComponents(string: derpMapURL)?.host, !host.isEmpty {
                "正在使用自建中转：\(host)"
            } else {
                "正在使用自建中转。"
            }
        case .mimi:
            "已开通的手机会自动切换。没开通的手机继续走免费线路，开通后再切换。"
        }
    }

    static let mimiPairingNote = "已开通的手机直接用上 Mimi 中转，没开通的先走免费线路。"

    static let selfHostedSteps = [
        "在有公网域名的服务器上部署 derper。",
        "把 DERP Map 文件发布到一个 HTTPS 地址。",
        "把地址填到下面，然后用手机重新扫码。"
    ]

    static let selfHostedGuideURL = URL(string: "https://github.com/gaixianggeng/mimi-remote/blob/main/docs/self-hosted-relay.md")!

    /// 只有会让正在使用的手机断开时才打断用户；改用 Mimi 不影响原有免费线路。
    static func needsReconnectionConfirmation(
        mode: TailcatRelayMode, url: String, tailcatEnabled: Bool, isManaged: Bool, currentURL: String
    ) -> Bool {
        tailcatEnabled && mode != .mimi && (isManaged || url != currentURL)
    }

    static func customURLValidationMessage(_ value: String) -> String? {
        guard !value.isEmpty else { return "请输入完整的 DERP Map HTTPS 地址。" }
        // 官方地址要求开通授权，不能作为自建地址保存后才发现错误并断开现有配置。
        if value == "https://api.code89757.com/v1/relay/tailcat-derp-map.json" {
            return "使用 Mimi 中转时，请直接选择“Mimi 中转”。"
        }
        guard value.count <= 2048,
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil, components.fragment == nil
        else { return "请输入不含账号、密码或片段的完整 HTTPS 地址。" }
        return nil
    }
}

/// 设置页：中转单选加恢复操作。配对窗口只用上面的单选，不带这些低频操作。
struct TailcatRelaySettings: View {
    let store: HostStore

    @Environment(\.openWindow) private var openWindow
    @State private var confirmsTailcatReset = false
    @State private var isApplyingRelay = false

    var body: some View {
        // 中转只属于内置连接；分组名不再和下面的选项重名。
        Section("内置连接") {
            TailcatRelayPicker(store: store, isApplying: $isApplyingRelay) { await showPairing() }
        }
        Section("配对与恢复") {
            Button("生成配对二维码") { Task { await showPairing() } }
                .disabled(!store.canPair || !store.availablePairingNetworks.contains(.tailcat) || store.isBusy)
            Button("重置内置连接…", role: .destructive) { confirmsTailcatReset = true }
                .disabled(!store.canChangeTailcat || !store.tailcatEnabled)
        }
        .confirmationDialog("重置内置连接？", isPresented: $confirmsTailcatReset, titleVisibility: .visible) {
            Button("重置内置连接", role: .destructive) { Task { await store.resetTailcat() } }
        } message: {
            Text("所有通过内置连接配对的设备需要重新扫码。Tailscale 和局域网连接不受影响。")
        }
    }

    private func showPairing() async {
        await store.refreshPairing(network: .tailcat)
        if store.pairingNetwork == .tailcat, store.pairing != nil {
            openWindow(id: AppWindow.pairing.rawValue)
        }
    }
}

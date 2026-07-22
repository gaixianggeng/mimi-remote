import AppKit
import SwiftUI

struct PairingView: View {
    let store: HostStore

    var body: some View {
        VStack(spacing: 18) {
            Text("配对 iPhone 或 iPad")
                .font(.title2.weight(.semibold))

            if let pairing = store.pairing {
                QRCodeView(value: pairing.pairURL)
                Text(pairing.endpoint)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                if !pairing.expiresAt.isEmpty {
                    Text("二维码有效期至 \(pairing.expiresAt)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(pairing.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button("复制短期配对链接") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pairing.pairURL, forType: .string)
                    }
                    Button("刷新二维码") {
                        Task { await store.refreshPairing() }
                    }
                }
            } else if let error = store.lastError {
                ContentUnavailableView(
                    "暂时无法生成二维码",
                    systemImage: "qrcode",
                    description: Text(error)
                )
                Button("重试") { Task { await store.refreshPairing() } }
            } else {
                ProgressView("正在生成短期配对二维码…")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if store.pairing == nil {
                await store.refreshPairing()
            }
        }
    }
}

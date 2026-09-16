import SwiftUI
import UIKit

/// 只保存滚动原因和数值，不收集正文、路径、主机或会话标识。非 Observable，记录不触发列表刷新。
@MainActor
final class ConversationScrollDiagnostics {
    static let shared = ConversationScrollDiagnostics()
    static let capacity = 800
    private(set) var isRecording = false
    private var entries: [String] = []
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var sequence = 0
    private var lastGeometryAt = -Double.infinity

    func start() {
        entries.removeAll(keepingCapacity: true)
        sequence = 0
        startedAt = ProcessInfo.processInfo.systemUptime
        lastGeometryAt = -Double.infinity
        isRecording = true
        record("start")
    }

    func stop() {
        record("stop")
        isRecording = false
    }

    func record(_ event: StaticString, _ detail: @autoclosure () -> String = "") {
        guard isRecording else { return }
        sequence += 1
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        entries.append("\(sequence) +\(String(format: "%.3f", elapsed)) \(event) \(detail())")
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    func geometry(_ old: ConversationTimelineScrollMetrics, _ new: ConversationTimelineScrollMetrics, interacting: Bool) {
        guard isRecording else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // 手势中最多每 100ms 采样一次；静止时的位移全部保留，便于对照程序写入。
        guard !interacting || now - lastGeometryAt >= 0.1 else { return }
        lastGeometryAt = now
        record("geometry", "offset=\(Int(new.contentOffsetY)) delta=\(Int(new.contentOffsetY - old.contentOffsetY)) height=\(Int(new.contentHeight)) near=\(new.isNearBottom) touch=\(interacting)")
    }

    func export() -> String {
        "Mimi conversation scroll trace v1\n" + entries.joined(separator: "\n")
    }
}

struct ConversationScrollDiagnosticsSection: View {
    @State private var recording = ConversationScrollDiagnostics.shared.isRecording
    @State private var copied = false

    var body: some View {
        Section {
            Toggle(L10n.text("ui.record_conversation_scroll"), isOn: $recording)
                .onChange(of: recording) { _, enabled in
                    if enabled {
                        copied = false
                        ConversationScrollDiagnostics.shared.start()
                    } else {
                        ConversationScrollDiagnostics.shared.stop()
                    }
                }
                .settingsStandardListRow()
                .accessibilityIdentifier("settings.scrollDiagnostics.record")
            Button(L10n.text(copied ? "ui.scroll_trace_copied" : "ui.stop_and_copy_scroll_trace")) {
                ConversationScrollDiagnostics.shared.stop()
                UIPasteboard.general.setItems(
                    [[UIPasteboard.typeAutomatic: ConversationScrollDiagnostics.shared.export()]],
                    options: [.localOnly: true]
                )
                recording = false
                copied = true
            }
            .settingsStandardListRow()
            .accessibilityIdentifier("settings.scrollDiagnostics.copy")
        } footer: {
            Text(L10n.text("ui.scroll_trace_help"))
        }
    }
}

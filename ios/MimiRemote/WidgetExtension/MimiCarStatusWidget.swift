import SwiftUI
import WidgetKit

private enum MimiCarStatusWidgetConstants {
    static let kind = "MimiCarStatusWidget"
    static let fallbackRefreshInterval: TimeInterval = 15 * 60
}

private enum WidgetL10n {
    static func text(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func format(_ key: String, _ arguments: String...) -> String {
        String(format: text(key), locale: .autoupdatingCurrent, arguments: arguments)
    }
}

private struct MimiCarStatusEntry: TimelineEntry {
    let date: Date
    let snapshot: CarStatusSnapshotV1?
}

private struct MimiCarStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> MimiCarStatusEntry {
        MimiCarStatusEntry(date: .now, snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (MimiCarStatusEntry) -> Void) {
        let snapshot = context.isPreview ? CarStatusSnapshotV1.widgetPreview() : CarStatusSnapshotStore.load()
        completion(MimiCarStatusEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MimiCarStatusEntry>) -> Void) {
        let now = Date.now
        let snapshot = CarStatusSnapshotStore.load()
        var entries = [MimiCarStatusEntry(date: now, snapshot: snapshot)]

        // 预排一个 stale entry，让系统即使没收到主 App 的 reload 也能准时显示“可能已过期”。
        if let snapshot {
            let staleDate = snapshot.publishedAt.addingTimeInterval(CarStatusSnapshotV1.defaultStaleInterval)
            if staleDate > now {
                entries.append(MimiCarStatusEntry(date: staleDate, snapshot: snapshot))
            }
        }

        // Widget 不主动联网；兜底回读 App Group，真实变更仍由主 App 主动触发 timeline reload。
        let nextRefresh = (entries.last?.date ?? now)
            .addingTimeInterval(MimiCarStatusWidgetConstants.fallbackRefreshInterval)
        completion(Timeline(entries: entries, policy: .after(nextRefresh)))
    }
}

private struct MimiCarStatusWidgetView: View {
    let entry: MimiCarStatusEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            identityRow
            Spacer(minLength: 8)
            content
            Spacer(minLength: 8)
            statusRow
        }
        .padding(14)
        .containerBackground(for: .widget) {
            Color(.secondarySystemBackground)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        // 父级 accessibilityLabel 同样包含项目和会话标题；整组标记敏感，
        // 避免锁屏 redaction 后 VoiceOver 仍从合并摘要朗读真实内容。
        .privacySensitive(entry.snapshot != nil)
    }

    private var identityRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("MIMI")
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(Color(red: 0.45, green: 0.24, blue: 0.88))
                .widgetAccentable()

            Spacer(minLength: 4)

            if let snapshot = entry.snapshot {
                Text(snapshot.activityDate, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = entry.snapshot {
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.projectDisplayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .privacySensitive()

                Text(snapshot.sessionTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .privacySensitive()
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(WidgetL10n.text("widget.car_status.empty_title"))
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(WidgetL10n.text("widget.car_status.empty_detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var statusRow: some View {
        let presentation = statusPresentation
        return HStack(spacing: 6) {
            Circle()
                .fill(presentation.color)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)

            Text(presentation.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    private var statusPresentation: (label: String, color: Color) {
        guard let snapshot = entry.snapshot else {
            return (WidgetL10n.text("widget.car_status.awaiting_sync"), .secondary)
        }

        switch snapshot.effectiveDisplayStatus(
            at: entry.date,
            staleAfter: CarStatusSnapshotV1.defaultStaleInterval
        ) {
        case .running:
            return (WidgetL10n.text("widget.car_status.running"), .blue)
        case .needsAttention:
            return (WidgetL10n.text("widget.car_status.needs_attention"), .orange)
        case .completed:
            return (WidgetL10n.text("widget.car_status.completed"), .green)
        case .failed:
            return (WidgetL10n.text("widget.car_status.failed"), .red)
        case .offline:
            return (WidgetL10n.text("widget.car_status.offline"), .secondary)
        case .stale:
            return (WidgetL10n.text("widget.car_status.stale"), .orange)
        }
    }

    private var accessibilitySummary: String {
        let presentation = statusPresentation
        guard let snapshot = entry.snapshot else {
            return WidgetL10n.format(
                "widget.car_status.accessibility_empty",
                presentation.label
            )
        }
        return WidgetL10n.format(
            "widget.car_status.accessibility_value",
            snapshot.projectDisplayName,
            snapshot.sessionTitle,
            presentation.label
        )
    }
}

private struct MimiCarStatusWidget: Widget {
    let kind = MimiCarStatusWidgetConstants.kind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MimiCarStatusProvider()) { entry in
            MimiCarStatusWidgetView(entry: entry)
        }
        .configurationDisplayName(WidgetL10n.text("widget.car_status.name"))
        .description(WidgetL10n.text("widget.car_status.description"))
        .supportedFamilies([.systemSmall])
        // CarPlay 等系统表面可移除背景；内容不依赖卡片底色表达状态。
        .containerBackgroundRemovable(true)
    }
}

@main
private struct MimiCarStatusWidgetBundle: WidgetBundle {
    var body: some Widget {
        MimiCarStatusWidget()
        MimiTurnLiveActivityWidget()
    }
}

#Preview(as: .systemSmall) {
    MimiCarStatusWidget()
} timeline: {
    MimiCarStatusEntry(date: .now, snapshot: .widgetPreview())
    MimiCarStatusEntry(
        date: .now,
        snapshot: .widgetPreview(
            publishedAt: .now.addingTimeInterval(-CarStatusSnapshotV1.defaultStaleInterval)
        )
    )
}

private extension CarStatusSnapshotV1 {
    static func widgetPreview(publishedAt: Date = .now) -> CarStatusSnapshotV1 {
        CarStatusSnapshotV1(
            profileID: "preview-profile",
            sessionID: "preview-session",
            projectDisplayName: "codex-ipad-agent",
            sessionTitle: "修复远程会话状态",
            displayStatus: .running,
            activityDate: .now.addingTimeInterval(-2 * 60),
            publishedAt: publishedAt
        )
    }
}

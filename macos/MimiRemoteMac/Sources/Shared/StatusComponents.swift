import SwiftUI

struct HostStatusHeader: View {
    let lifecycle: HostLifecycleState
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: lifecycle.symbolName)
                .font(compact ? .title2 : .largeTitle)
                .foregroundStyle(statusColor)
                .symbolEffect(
                    .rotate,
                    options: .repeating,
                    isActive: !reduceMotion && (lifecycle == .loading || lifecycle == .starting)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(lifecycle.title)
                    .font(compact ? .headline : .title2.weight(.semibold))
                if let detail = lifecycle.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(compact ? 2 : 4)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        switch lifecycle {
        case .ready: .green
        case .loading, .starting: .blue
        case .notConfigured, .migrationRequired, .degraded: .orange
        case .stopped: .secondary
        case .failed: .red
        }
    }
}

struct InfoCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}

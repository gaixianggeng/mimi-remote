import SwiftUI
import UIKit

enum ShareJourneyPersona: Equatable {
    case newChapter
    case sunriseStarter
    case focusedBuilder
    case daylightMaker
    case nightCreator

    var title: String {
        switch self {
        case .newChapter:
            return L10n.text("ui.share_journey_persona_new_chapter")
        case .sunriseStarter:
            return L10n.text("ui.share_journey_persona_sunrise")
        case .focusedBuilder:
            return L10n.text("ui.share_journey_persona_focused")
        case .daylightMaker:
            return L10n.text("ui.share_journey_persona_daylight")
        case .nightCreator:
            return L10n.text("ui.share_journey_persona_night")
        }
    }

    init(favoriteHour: Int?) {
        guard let favoriteHour else {
            self = .newChapter
            return
        }

        switch favoriteHour {
        case 5..<9:
            self = .sunriseStarter
        case 9..<13:
            self = .focusedBuilder
        case 13..<19:
            self = .daylightMaker
        default:
            self = .nightCreator
        }
    }
}

struct ShareJourneySnapshot: Equatable {
    let companionDay: Int
    let taskCount: Int
    let workspaceCount: Int
    let favoriteHour: Int?
    let persona: ShareJourneyPersona

    init(
        sessions: [AgentSession],
        fallbackWorkspaceCount: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        // 只汇总当前设备已经同步的非敏感元数据；项目名、标题、对话和代码都不会进入卡片。
        let uniqueSessions = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let visibleSessions = Array(uniqueSessions.values)
        taskCount = visibleSessions.count

        let sessionWorkspaceIDs = Set(
            visibleSessions
                .map(\.projectID)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        )
        workspaceCount = sessionWorkspaceIDs.isEmpty
            ? max(0, fallbackWorkspaceCount)
            : sessionWorkspaceIDs.count

        let activityDates = visibleSessions.compactMap {
            $0.createdAt ?? $0.updatedAt ?? $0.recencyAt
        }
        let firstActivity = activityDates.min() ?? now
        let firstDay = calendar.startOfDay(for: firstActivity)
        let currentDay = calendar.startOfDay(for: now)
        let elapsedDays = calendar.dateComponents([.day], from: firstDay, to: currentDay).day ?? 0
        companionDay = max(1, elapsedDays + 1)

        // 相同次数时优先较早的小时，确保同一份数据每次导出都得到稳定结果。
        let hourCounts = activityDates.reduce(into: [Int: Int]()) { counts, date in
            counts[calendar.component(.hour, from: date), default: 0] += 1
        }
        favoriteHour = hourCounts.keys.sorted().max { lhs, rhs in
            let leftCount = hourCounts[lhs, default: 0]
            let rightCount = hourCounts[rhs, default: 0]
            if leftCount == rightCount {
                return lhs > rhs
            }
            return leftCount < rightCount
        }
        persona = ShareJourneyPersona(favoriteHour: favoriteHour)
    }
}

struct ShareJourneySettingsRow: View {
    let snapshot: ShareJourneySnapshot

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.29, green: 0.08, blue: 0.31),
                                Color(red: 0.93, green: 0.50, blue: 0.56)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("ui.share_journey_title"))
                    .font(.body.weight(.medium))
                Text(snapshot.persona.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(L10n.format("ui.share_journey_compact_day", snapshot.companionDay))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color(red: 0.29, green: 0.08, blue: 0.31))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.white.opacity(0.72), in: Capsule())
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.shareJourney")
    }
}

struct ShareJourneyView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var now = Date()
    @State private var isRendering = false
    @State private var activityPayload: ShareJourneyActivityPayload?
    @State private var showsRenderError = false

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let snapshot = snapshot

        ScrollView {
            VStack(spacing: 18) {
                ShareJourneyCard(snapshot: snapshot)
                    .frame(maxWidth: 420)
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(.white.opacity(0.72), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.16), radius: 24, y: 14)
                    .accessibilityIdentifier("shareJourney.card")

                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        L10n.text("ui.share_journey_privacy_note"),
                        systemImage: "hand.raised.fill"
                    )
                    Label(
                        L10n.text("ui.share_journey_share_hint"),
                        systemImage: "square.and.arrow.up"
                    )
                }
                .font(themeStore.uiFont(.footnote))
                .foregroundStyle(tokens.secondaryText)
                .frame(maxWidth: 420, alignment: .leading)
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 92)
            .frame(maxWidth: .infinity)
        }
        .background(tokens.background.ignoresSafeArea())
        .navigationTitle(L10n.text("ui.share_journey_navigation_title"))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            shareActionBar(snapshot: snapshot, tokens: tokens)
        }
        .sheet(item: $activityPayload) { payload in
            ShareJourneyActivityView(image: payload.image)
                .presentationDetents([.medium, .large])
        }
        .alert(
            L10n.text("ui.share_journey_render_error_title"),
            isPresented: $showsRenderError
        ) {
            Button(L10n.text("ui.close"), role: .cancel) {}
        } message: {
            Text(L10n.text("ui.share_journey_render_error_message"))
        }
    }

    private var snapshot: ShareJourneySnapshot {
        ShareJourneySnapshot(
            sessions: sessionStore.sessions,
            fallbackWorkspaceCount: sessionStore.sidebarProjects.count,
            now: now
        )
    }

    private func shareActionBar(snapshot: ShareJourneySnapshot, tokens: ThemeTokens) -> some View {
        Button {
            renderAndShare(snapshot: snapshot)
        } label: {
            HStack(spacing: 9) {
                if isRendering {
                    ProgressView()
                        .tint(tokens.primaryActionForeground)
                } else {
                    Image(systemName: "square.and.arrow.up")
                }
                Text(L10n.text("ui.share_journey_share_button"))
            }
            .font(themeStore.uiFont(.headline, weight: .semibold))
            .frame(maxWidth: 420, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
        .tint(tokens.primaryAction)
        .disabled(isRendering)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(WorkbenchMaterial.surface)
        .accessibilityIdentifier("shareJourney.share")
    }

    @MainActor
    private func renderAndShare(snapshot: ShareJourneySnapshot) {
        isRendering = true
        defer { isRendering = false }

        // 以 360pt 设计稿渲染 3x，导出恰好是适合小红书的 1080 × 1440 PNG。
        let renderer = ImageRenderer(
            content: ShareJourneyCard(snapshot: snapshot)
                .frame(width: 360, height: 480)
                .environment(\.colorScheme, .light)
        )
        renderer.scale = 3
        renderer.isOpaque = true

        guard let image = renderer.uiImage else {
            showsRenderError = true
            return
        }
        activityPayload = ShareJourneyActivityPayload(image: image)
    }
}

struct ShareJourneyCard: View {
    let snapshot: ShareJourneySnapshot

    var body: some View {
        GeometryReader { proxy in
            let scale = max(0.1, proxy.size.width / 360)

            ZStack {
                Image("ShareJourneyBackground")
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .accessibilityHidden(true)

                Color.white.opacity(0.06)

                VStack(alignment: .leading, spacing: 0) {
                    brandHeader(scale: scale)

                    Spacer(minLength: 24 * scale)

                    personaPill(scale: scale)

                    Text(L10n.text("ui.share_journey_together"))
                        .font(.system(size: 22 * scale, weight: .semibold, design: .rounded))
                        .foregroundStyle(ShareJourneyPalette.ink.opacity(0.82))
                        .padding(.top, 13 * scale)

                    Text(L10n.format("ui.share_journey_day_value", snapshot.companionDay))
                        .font(.system(size: 43 * scale, weight: .bold, design: .rounded))
                        .tracking(-1.25 * scale)
                        .monospacedDigit()
                        .foregroundStyle(ShareJourneyPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Spacer(minLength: 18 * scale)

                    HStack(spacing: 8 * scale) {
                        stat(
                            value: String(snapshot.taskCount),
                            label: L10n.text("ui.share_journey_tasks"),
                            scale: scale
                        )
                        stat(
                            value: String(snapshot.workspaceCount),
                            label: L10n.text("ui.share_journey_workspaces"),
                            scale: scale
                        )
                        stat(
                            value: favoriteHourText,
                            label: L10n.text("ui.share_journey_peak_hour"),
                            scale: scale
                        )
                    }

                    Text(L10n.text("ui.share_journey_quote"))
                        .font(.system(size: 14 * scale, weight: .medium, design: .rounded))
                        .foregroundStyle(ShareJourneyPalette.ink.opacity(0.78))
                        .lineSpacing(3 * scale)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 17 * scale)

                    Spacer(minLength: 12 * scale)

                    footer(scale: scale)
                }
                .padding(26 * scale)
            }
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .accessibilityElement(children: .combine)
    }

    private func brandHeader(scale: CGFloat) -> some View {
        HStack(spacing: 8 * scale) {
            ZStack {
                Circle()
                    .fill(ShareJourneyPalette.ink)
                Image(systemName: "sparkles")
                    .font(.system(size: 11 * scale, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 28 * scale, height: 28 * scale)

            VStack(alignment: .leading, spacing: 0) {
                Text("Mimi Remote")
                    .font(.system(size: 10 * scale, weight: .bold, design: .rounded))
                    .tracking(1.15 * scale)
                    .textCase(.uppercase)
                    .foregroundStyle(ShareJourneyPalette.ink)
                Text(L10n.text("ui.share_journey_eyebrow"))
                    .font(.system(size: 8.5 * scale, weight: .medium, design: .rounded))
                    .foregroundStyle(ShareJourneyPalette.ink.opacity(0.58))
            }

            Spacer()

            Image(systemName: "arrow.up.right")
                .font(.system(size: 11 * scale, weight: .semibold))
                .foregroundStyle(ShareJourneyPalette.ink.opacity(0.58))
                .frame(width: 28 * scale, height: 28 * scale)
                .background(.white.opacity(0.56), in: Circle())
        }
    }

    private func personaPill(scale: CGFloat) -> some View {
        Label(snapshot.persona.title, systemImage: "sparkle")
            .font(.system(size: 11 * scale, weight: .semibold, design: .rounded))
            .foregroundStyle(ShareJourneyPalette.ink)
            .padding(.horizontal, 11 * scale)
            .padding(.vertical, 7 * scale)
            .background(.white.opacity(0.68), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.88), lineWidth: 0.7 * scale)
            }
    }

    private func stat(value: String, label: String, scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3 * scale) {
            Text(value)
                .font(.system(size: 20 * scale, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(ShareJourneyPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(label)
                .font(.system(size: 9.5 * scale, weight: .semibold, design: .rounded))
                .foregroundStyle(ShareJourneyPalette.ink.opacity(0.57))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(11 * scale)
        .frame(maxWidth: .infinity, minHeight: 70 * scale, alignment: .leading)
        .background(.white.opacity(0.66), in: RoundedRectangle(cornerRadius: 14 * scale, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14 * scale, style: .continuous)
                .stroke(.white.opacity(0.84), lineWidth: 0.7 * scale)
        }
    }

    private func footer(scale: CGFloat) -> some View {
        HStack(spacing: 6 * scale) {
            Image(systemName: "iphone.and.arrow.forward")
            Text(L10n.text("ui.share_journey_brand_line"))
        }
        .font(.system(size: 9.5 * scale, weight: .semibold, design: .rounded))
        .foregroundStyle(ShareJourneyPalette.ink)
        .padding(.horizontal, 10 * scale)
        .padding(.vertical, 7 * scale)
        .background(.white.opacity(0.72), in: Capsule())
    }

    private var favoriteHourText: String {
        guard let favoriteHour = snapshot.favoriteHour else {
            return L10n.text("ui.share_journey_locked")
        }

        var calendar = Calendar.current
        calendar.locale = AppLanguage.stored().locale
        guard let date = calendar.date(
            bySettingHour: favoriteHour,
            minute: 0,
            second: 0,
            of: Date()
        ) else {
            return String(format: "%02d:00", favoriteHour)
        }
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.stored().locale
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: date)
    }
}

private enum ShareJourneyPalette {
    static let ink = Color(red: 0.20, green: 0.055, blue: 0.22)
}

private struct ShareJourneyActivityPayload: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct ShareJourneyActivityView: UIViewControllerRepresentable {
    let image: UIImage

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

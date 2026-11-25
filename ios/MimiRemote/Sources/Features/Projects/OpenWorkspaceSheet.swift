import QuickLook
import SwiftUI
import UIKit

/// 每次弹出「打开文件夹」Sheet 持有独立的可标识模型，确保父视图（工作区/会话/壳层）
/// 在后台轮询或 SessionStore 更新时重绘，不会重建或清空正在编辑的手动路径草稿（#1107）。
struct OpenWorkspaceSheetPresentation: Identifiable {
    let id = UUID()
    let model: OpenWorkspaceSheetModel

    @MainActor
    init(model: OpenWorkspaceSheetModel? = nil) {
        self.model = model ?? OpenWorkspaceSheetModel()
    }
}

/// 「打开文件夹」Sheet 的状态与动作容器。
///
/// 目录浏览和手动输入路径都保存在这里，不直接挂在易被父层刷新重建的视图局部 `@State` 上；
/// 同时只持有 `SessionStore` 的弱引用供用户动作调用，不把全局会话轮询订阅进 Sheet 视图树。
@MainActor
final class OpenWorkspaceSheetModel: ObservableObject {
    @Published var path = "" {
        didSet {
            if path != oldValue {
                localError = nil
            }
        }
    }
    @Published var isOpening = false
    @Published var localError: String?
    @Published var presentationDetent = OpenWorkspaceSheet.compactPresentationDetent
    /// 手动输入是备用通道，默认折叠成一行，首屏完整留给目录列表。
    @Published var isManualPathExpanded = false

    @Published var browsePath: String?
    /// 首次不带 path 的浏览落在服务端默认浏览根上，正好是授权边界的下沿。
    /// 记住它，路径条才能只把边界内的层级画成可点。
    @Published var browseRootPath: String?
    @Published var browseParentPath: String?
    @Published var browseEntries: [DirectoryEntry] = []
    @Published var browseTruncated = false
    @Published var isBrowsing = false
    @Published var browseError: String?
    @Published var previewURL: URL?
    @Published var previewError: String?
    @Published var previewingPath: String?

    // 快速连点目录时让最后一次请求胜出，避免慢响应把列表回写成旧目录。
    private var browseRequestID = 0
    private var hasStartedInitialBrowse = false
    private weak var sessionStore: SessionStore?
    private var onOpened: (String) -> Void = { _ in }
    private var dismissAction: (() -> Void)?

    var trimmedPath: String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canOpenTypedPath: Bool {
        !isOpening && !trimmedPath.isEmpty
    }

    func attach(
        sessionStore: SessionStore,
        onOpened: @escaping (String) -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.sessionStore = sessionStore
        self.onOpened = onOpened
        self.dismissAction = dismiss
    }

    func updateManualPath(_ next: String) {
        guard path != next else { return }
        path = next
    }

    func handleManualPathFocusChange(_ isFocused: Bool) {
        // 键盘会显著压缩目录与说明区；用系统 large detent 给输入留出空间，
        // 关闭键盘后不强制回落，保留用户对 Sheet 高度的控制。
        if isFocused {
            presentationDetent = .large
        }
    }

    func startInitialBrowseIfNeeded() async {
        guard !hasStartedInitialBrowse else { return }
        hasStartedInitialBrowse = true
        // 默认进入服务端浏览根（第一个 scan root），失败时仍可手动输入路径。
        await browse(to: "")
    }

    func openCurrentBrowsePath() {
        guard let browsePath else { return }
        Task { await open(path: browsePath) }
    }

    func openTypedPath() {
        guard canOpenTypedPath else { return }
        Task { await open(path: path) }
    }

    func browse(to target: String) async {
        guard let sessionStore else { return }
        browseRequestID += 1
        let requestID = browseRequestID
        isBrowsing = true
        browseError = nil
        do {
            let response = try await sessionStore.listDirectories(path: target)
            guard requestID == browseRequestID else {
                return
            }
            guard !Task.isCancelled else {
                isBrowsing = false
                return
            }
            browsePath = response.path
            if target.isEmpty, browseRootPath == nil {
                browseRootPath = response.path
            }
            browseParentPath = response.parentPath
            browseEntries = response.entries
            browseTruncated = response.truncated ?? false
            previewError = nil
            isBrowsing = false
        } catch {
            guard requestID == browseRequestID else {
                return
            }
            isBrowsing = false
            guard !isCancellationError(error) else {
                return
            }
            browseError = userFacingBrowseError(error)
        }
    }

    func preview(_ entry: DirectoryEntry) async {
        guard entry.isPreviewable, let sessionStore else {
            return
        }
        let targetPath = entry.path
        previewingPath = targetPath
        previewError = nil
        defer {
            if previewingPath == targetPath {
                previewingPath = nil
            }
        }
        do {
            previewURL = try await sessionStore.previewFile(path: targetPath)
        } catch {
            guard !isCancellationError(error) else {
                return
            }
            previewError = FilePreviewErrorPresentation.message(for: error)
        }
    }

    func open(path: String) async {
        guard let sessionStore else { return }
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            localError = L10n.text("ui.please_enter_the_directory_path_in_the_development")
            return
        }
        isOpening = true
        localError = nil
        defer { isOpening = false }
        switch await sessionStore.openWorkspaceOutcome(path: targetPath) {
        case .opened(let workspaceID):
            onOpened(workspaceID)
            dismissAction?()
        case .cancelled:
            // 关闭 Sheet、切主机或后台凭据挂起都属于生命周期取消；保留输入供用户恢复后重试。
            return
        case .failed(let message):
            localError = userFacingOpenWorkspaceError(message, path: targetPath)
        }
    }

    private func userFacingBrowseError(_ error: Error) -> String {
        if case AgentAPIError.server(let status, _) = error, status == 404 || status == 405 {
            return L10n.text("ui.the_current_agentd_version_does_not_support_directory")
        }
        if case AgentAPIError.server(let status, _) = error, status == 403 {
            return L10n.text("ui.the_directory_is_not_within_authorization_scope_or")
        }
        return error.localizedDescription
    }

    private func userFacingOpenWorkspaceError(_ message: String?, path: String) -> String {
        let fallback = L10n.format("ui.unable_to_open_value", path)
        guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }
        let lowercased = message.lowercased()
        if lowercased.contains("allowlist") ||
            message.contains("允许范围") ||
            message.contains("HTTP 403") {
            return L10n.format("ui.value_is_not_yet_within_the_authorized_scope", path)
        }
        return message
    }
}

struct OpenWorkspaceSheet: View {
    static let compactPresentationDetent: PresentationDetent = .fraction(0.82)
    /// 图标底板宽 + 与名称的间距。分隔线按同一常量内缩，让线头正好落在名称基线上。
    fileprivate static let rowTextInset: CGFloat = 42

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sessionStore: SessionStore

    private let externalModel: OpenWorkspaceSheetModel?
    @StateObject private var fallbackModel = OpenWorkspaceSheetModel()
    var onOpened: (String) -> Void = { _ in }

    init(
        model: OpenWorkspaceSheetModel? = nil,
        onOpened: @escaping (String) -> Void = { _ in }
    ) {
        self.externalModel = model
        self.onOpened = onOpened
    }

    private var resolvedModel: OpenWorkspaceSheetModel {
        externalModel ?? fallbackModel
    }

    var body: some View {
        let model = resolvedModel
        model.attach(
            sessionStore: sessionStore,
            onOpened: onOpened,
            dismiss: { dismiss() }
        )
        // SessionStore 轮询更新时只刷新最外层弱引用，内层以模型身份判等跳过重绘，
        // 不把全局列表刷新传导到正在粘贴/编辑的手动路径输入框（#1107）。
        return OpenWorkspaceSheetContent(model: model)
            .equatable()
    }
}

private struct OpenWorkspaceSheetContent: View, Equatable {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var themeStore: ThemeStore
    @ObservedObject var model: OpenWorkspaceSheetModel

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        NavigationStack {
            directoryBrowser
                .navigationTitle(L10n.text("ui.open_workspace"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if #available(iOS 26.0, *) {
                        ToolbarItem(placement: .cancellationAction) {
                            cancelButton(tokens: tokens)
                        }
                        // 取消是安静文本，不该再套一层系统共享玻璃底板：
                        // 一屏只留「打开」一处实心控件，主次才立得住。
                        .sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(placement: .cancellationAction) {
                            cancelButton(tokens: tokens)
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        WorkspaceOpenCurrentDirectoryToolbarButton(
                            isOpening: model.isOpening,
                            isDisabled: model.browsePath == nil || model.isOpening || model.isBrowsing,
                            action: { model.openCurrentBrowsePath() }
                        )
                    }
                }
                .task {
                    await model.startInitialBrowseIfNeeded()
                }
                .quickLookPreview($model.previewURL)
        }
        .tint(tokens.primaryAction)
        // 目录浏览、路径条与说明文字共用一张画布，行本身不再另铺白底：
        // 一屏只有一层底色时，20 多行的节奏才由行距和分隔线决定，而不是由色块堆叠决定。
        .presentationBackground(tokens.sidebarBackground)
        // 默认只占可用高度的约八成，保留背景上下文；仍允许按系统手势上拉到全屏。
        .presentationDetents(
            [OpenWorkspaceSheet.compactPresentationDetent, .large],
            selection: $model.presentationDetent
        )
        .presentationDragIndicator(.visible)
    }

    private func cancelButton(tokens: ThemeTokens) -> some View {
        Button(L10n.text("ui.cancel"), role: .cancel) {
            dismiss()
        }
        .buttonStyle(.plain)
        .font(themeStore.uiFont(size: 15))
        .foregroundStyle(tokens.secondaryText)
        .frame(minWidth: 44, minHeight: 44)
        // 打开请求完成前禁止关闭弹窗，避免后台任务在取消后仍切换当前工作区。
        .disabled(model.isOpening)
        .accessibilityIdentifier("workspace.open.cancel")
    }

    @ViewBuilder
    private var directoryBrowser: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        let list = List {
            if let localError = model.localError {
                browseNotice(localError, title: L10n.text("ui.open_failed"))
            }

            childDirectoriesSection
            manualPathSection
        }
        // 目录浏览是首要任务。平铺列表去掉 Form 的大面积分组卡片，
        // 只用原生行距和分隔线表达层级，同时保留系统滚动与键盘行为。
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        // 静止时首行与路径条留一道窄缝；滚动后内容仍从路径条底下穿过。
        .contentMargins(.top, 6, for: .scrollContent)
        .background(tokens.sidebarBackground)
        // 路径条属于浮在内容之上的控制层，不随目录列表滚走：深目录里「我在哪」
        // 必须始终可读，同时列表从它底下穿过，边界交给 scroll edge 表达而不是分割线。
        .safeAreaInset(edge: .top, spacing: 0) {
            pathBar
        }

        if #available(iOS 26.0, *) {
            // 行接近路径条时先被系统渐进虚化，再进入材质后方；两段虚化连起来，
            // 才不会出现「清晰的行忽然贴到层级文字背后」。
            list.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            list
        }
    }

    @ViewBuilder
    private var pathBar: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        WorkspaceCurrentDirectoryCard(
            path: model.browsePath ?? "",
            rootPath: model.browseRootPath,
            parentPath: model.browseParentPath,
            isBrowsing: model.isBrowsing,
            isOpening: model.isOpening,
            onNavigate: { target in
                Task { await model.browse(to: target) }
            }
        )
        .background {
            WorkspaceBrowsePathBarSurface(tokens: tokens)
                .ignoresSafeArea(edges: .horizontal)
        }
    }

    @ViewBuilder
    private var childDirectoriesSection: some View {
        Section {
            if model.isBrowsing && model.browseEntries.isEmpty {
                // 只有首次进入才让位给加载态；目录之间切换时保留上一屏内容，
                // 避免每点一层就闪一次空列表。
                browseStatusBlock {
                    LoadingOrbit(size: .regular)
                    statusCaption(L10n.text("ui.loading_catalog"))
                }
            } else if let browseError = model.browseError {
                browseNotice(browseError) {
                    Task { await model.browse(to: model.browsePath ?? "") }
                }
            } else if model.browseEntries.isEmpty {
                browseStatusBlock {
                    statusGlyph("folder")
                    statusCaption(L10n.text("ui.no_subdirectories_to_enter_or_files_to_preview"))
                }
            } else {
                entryRows
            }
        } footer: {
            // 原来这里有一个「内容」标题。路径条已经说明当前层级，标题不携带新信息，
            // 只是在首屏再占一行；边界改由路径条的磨砂层表达。
            browseFooter
        }
        // 路径条已经用磨砂层划分控制区，第一项上方再画线只会形成重复边界；
        // 尾部说明与手动输入之间同理，靠留白分区就够。
        .listSectionSeparator(.hidden)
    }

    @ViewBuilder
    private var entryRows: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        ForEach(model.browseEntries) { entry in
            let isReachable = entry.canBrowse || entry.isPreviewable

            Button {
                if entry.isDir {
                    Task { await model.browse(to: entry.path) }
                } else {
                    Task { await model.preview(entry) }
                }
            } label: {
                WorkspaceBrowseEntryRow(
                    entry: entry,
                    isPreviewing: model.previewingPath == entry.path,
                    isReachable: isReachable
                )
            }
            .buttonStyle(WorkspaceBrowseRowButtonStyle(tokens: tokens, reduceMotion: reduceMotion))
            .disabled(model.isOpening || model.isBrowsing || model.previewingPath != nil || !isReachable)
            // 切目录时旧内容整体退到背景，等新一屏落位再回到前台；
            // 位置不跳，只有明暗变化，读者的视线不会被重排打断。
            .opacity(model.isBrowsing ? 0.35 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.isBrowsing)
            .listRowBackground(Color.clear)
            // List 默认还会在内容外增加上下 inset；归零后行高完全由行内容决定。
            // 横向沿用原生 16pt 边距。
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowSeparatorTint(tokens.border.opacity(0.55))
            // 分隔线从名称起笔，图标列留空：一列图标底板因此连成视觉上的一条竖轴。
            .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                dimensions[.leading] + OpenWorkspaceSheet.rowTextInset
            }
        }

        if let previewError = model.previewError {
            browseNotice(previewError)
        }
    }

    @ViewBuilder
    private var browseFooter: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Text(
            model.browseTruncated
                ? L10n.text("ui.the_directory_is_too_large_only_the_front")
                : L10n.text("ui.hidden_directories_library_and_common_cache_directories_will")
        )
        .font(themeStore.uiFont(size: 12))
        .foregroundStyle(tokens.tertiaryText)
        .padding(.top, 14)
        .padding(.bottom, 4)
        // 说明文字属于同一张画布；不铺自己的白底，否则列表尾部会多出一条色带。
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var manualPathSection: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Section {
            // 在 List 中使用内联折叠容器（而非系统 outline DisclosureGroup），避免 UICollectionView
            // 把输入区拆成独立子 cell 并在刷新/滚动时反复重建输入框。
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(reduceMotion ? nil : .default) {
                        model.isManualPathExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "keyboard")
                            .font(themeStore.uiFont(size: 13, weight: .medium))
                            .foregroundStyle(tokens.tertiaryText)
                            .frame(width: 20)
                        Text(L10n.text("ui.enter_path_manually"))
                            .font(themeStore.uiFont(size: 14, weight: .medium))
                            .foregroundStyle(tokens.secondaryText)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(themeStore.uiFont(size: 12, weight: .semibold))
                            .foregroundStyle(tokens.tertiaryText)
                            .rotationEffect(.degrees(model.isManualPathExpanded ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(
                    model.isManualPathExpanded ? L10n.text("ui.expanded") : L10n.text("ui.collected")
                )
                .accessibilityIdentifier("workspace.open.manualPath.toggle")

                if model.isManualPathExpanded {
                    VStack(alignment: .leading, spacing: 12) {
                        OpenWorkspaceManualPathTextField(
                            placeholder: "/Users/me/finance",
                            text: Binding(
                                get: { model.path },
                                set: { model.updateManualPath($0) }
                            ),
                            fontSize: themeStore.scaledFontSize(13),
                            textColor: UIColor(tokens.primaryText),
                            placeholderColor: UIColor(tokens.tertiaryText),
                            onFocusChange: { isFocused in
                                model.handleManualPathFocusChange(isFocused)
                            },
                            onSubmit: {
                                model.openTypedPath()
                            }
                        )
                        // 路径是等宽内容：斜杠与层级在等宽字下才对得齐，也更容易核对粘贴结果。
                        .padding(.horizontal, 12)
                        .frame(minHeight: 42)
                        .background(
                            tokens.inputBackground,
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(tokens.border.opacity(0.6), lineWidth: 1)
                        }

                        Button {
                            model.openTypedPath()
                        } label: {
                            Text(model.isOpening ? L10n.text("ui.opening") : L10n.text("ui.open_the_input_path"))
                                .font(themeStore.uiFont(size: 14, weight: .semibold))
                                .foregroundStyle(model.canOpenTypedPath ? tokens.accentText : tokens.tertiaryText)
                                .frame(maxWidth: .infinity, minHeight: 42)
                                .background(
                                    model.canOpenTypedPath ? tokens.accentSoft : tokens.accentSoft.opacity(0.5),
                                    in: Capsule()
                                )
                                .overlay {
                                    Capsule().strokeBorder(tokens.border.opacity(0.55), lineWidth: 1)
                                }
                                .contentShape(Capsule())
                        }
                        // 备用通道用淡底按钮：与工具栏那颗实心「打开」区分主次，
                        // 也不会在没输入时把系统灰底板压在这张暖色画布上。
                        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
                        .disabled(!model.canOpenTypedPath)
                        .accessibilityIdentifier("workspace.open.manualPath.submit")

                        Text(L10n.text("ui.you_can_directly_paste_the_absolute_path_in"))
                            .font(themeStore.uiFont(size: 12))
                            .foregroundStyle(tokens.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16))
            .listRowSeparator(.hidden)
        }
        .listSectionSeparator(.hidden)
    }

    /// 错误不再另起一节标题，而是收成一张与行同宽的提示卡：
    /// 出错时视线仍留在列表位置上，恢复后卡片消失，不会留下一个空标题。
    @ViewBuilder
    private func browseNotice(
        _ message: String,
        title: String? = nil,
        retry: (() -> Void)? = nil
    ) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(themeStore.uiFont(size: 13, weight: .semibold))
                .foregroundStyle(tokens.warning)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 6) {
                if let title {
                    Text(title)
                        .font(themeStore.uiFont(size: 12, weight: .semibold))
                        .foregroundStyle(tokens.warning)
                }
                Text(message)
                    .font(themeStore.uiFont(size: 13))
                    .foregroundStyle(tokens.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let retry {
                    Button(action: retry) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.clockwise")
                                .font(themeStore.uiFont(size: 12, weight: .semibold))
                            Text(L10n.text("ui.try_again"))
                                .font(themeStore.uiFont(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(tokens.accent)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            tokens.warning.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func browseStatusBlock(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 12) {
            content()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowSeparator(.hidden)
    }

    private func statusGlyph(_ systemImage: String) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return Image(systemName: systemImage)
            .font(themeStore.uiFont(size: 26, weight: .light))
            .foregroundStyle(tokens.tertiaryText.opacity(0.7))
    }

    private func statusCaption(_ text: String) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return Text(text)
            .font(themeStore.uiFont(size: 13))
            .foregroundStyle(tokens.tertiaryText)
            .multilineTextAlignment(.center)
    }
}

/// 稳定的手动路径输入框：
/// 1. 覆写 `paste(_:)` 并同时监听 `editingChanged` / `textDidChangeNotification` / `didEndEditing`，
///    保证系统粘贴菜单、键盘粘贴或拖拽文本都立即写回 `OpenWorkspaceSheetModel`。
/// 2. `updateUIView` 以 `lastSyncedText` 和 `markedTextRange == nil` 把关，避免视图重绘把
///    用户刚粘贴或正在输入的内容回写成旧值或空串（#1107）。
struct OpenWorkspaceManualPathTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let fontSize: CGFloat
    let textColor: UIColor
    let placeholderColor: UIColor
    let onFocusChange: (Bool) -> Void
    let onSubmit: () -> Void

    func makeUIView(context: Context) -> ManualPathUITextField {
        let textField = ManualPathUITextField()
        textField.text = text
        context.coordinator.lastSyncedText = text
        textField.delegate = context.coordinator
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.smartQuotesType = .no
        textField.smartDashesType = .no
        textField.returnKeyType = .go
        textField.clearButtonMode = .whileEditing
        textField.accessibilityIdentifier = "workspace.open.manualPath"
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textDidChange(_:)),
            for: .editingChanged
        )
        textField.onTextMutated = { [weak coordinator = context.coordinator] field in
            coordinator?.syncFromTextField(field)
        }
        context.coordinator.observeTextChanges(of: textField)
        applyAppearance(to: textField)
        return textField
    }

    func updateUIView(_ uiView: ManualPathUITextField, context: Context) {
        context.coordinator.parent = self
        applyAppearance(to: uiView)

        guard uiView.markedTextRange == nil,
              context.coordinator.lastSyncedText != text
        else {
            return
        }

        let previousText = uiView.text ?? ""
        let selectedRange = context.coordinator.selectedRange(in: uiView)
        uiView.text = text
        context.coordinator.lastSyncedText = text
        context.coordinator.setSelectedRange(
            TextSelectionPolicy.rangeAfterExternalTextSync(
                previousText: previousText,
                nextText: text,
                previousRange: selectedRange
            ),
            in: uiView
        )
    }

    private func applyAppearance(to textField: UITextField) {
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if textField.font != font {
            textField.font = font
        }
        textField.textColor = textColor
        textField.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: placeholderColor,
                .font: font,
            ]
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class ManualPathUITextField: UITextField {
        var onTextMutated: ((UITextField) -> Void)?

        override func paste(_ sender: Any?) {
            super.paste(sender)
            onTextMutated?(self)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: OpenWorkspaceManualPathTextField
        var lastSyncedText = ""
        nonisolated(unsafe) private var textDidChangeObserver: NSObjectProtocol?

        init(_ parent: OpenWorkspaceManualPathTextField) {
            self.parent = parent
        }

        deinit {
            if let textDidChangeObserver {
                NotificationCenter.default.removeObserver(textDidChangeObserver)
            }
        }

        func observeTextChanges(of textField: UITextField) {
            if let textDidChangeObserver {
                NotificationCenter.default.removeObserver(textDidChangeObserver)
            }
            textDidChangeObserver = NotificationCenter.default.addObserver(
                forName: UITextField.textDidChangeNotification,
                object: textField,
                queue: .main
            ) { [weak self, weak textField] _ in
                MainActor.assumeIsolated {
                    guard let self, let textField else { return }
                    self.syncFromTextField(textField)
                }
            }
        }

        @objc func textDidChange(_ textField: UITextField) {
            syncFromTextField(textField)
        }

        func syncFromTextField(_ textField: UITextField) {
            let next = textField.text ?? ""
            guard next != lastSyncedText else {
                return
            }
            lastSyncedText = next
            parent.text = next
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.onFocusChange(true)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            syncFromTextField(textField)
            parent.onFocusChange(false)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            syncFromTextField(textField)
            parent.onSubmit()
            return true
        }

        func selectedRange(in textField: UITextField) -> NSRange {
            guard let selectedTextRange = textField.selectedTextRange else {
                let length = ((textField.text ?? "") as NSString).length
                return NSRange(location: length, length: 0)
            }
            let location = textField.offset(from: textField.beginningOfDocument, to: selectedTextRange.start)
            let length = textField.offset(from: selectedTextRange.start, to: selectedTextRange.end)
            return NSRange(location: location, length: length)
        }

        func setSelectedRange(_ range: NSRange, in textField: UITextField) {
            guard
                let start = textField.position(from: textField.beginningOfDocument, offset: range.location),
                let end = textField.position(from: start, offset: range.length)
            else {
                return
            }
            textField.selectedTextRange = textField.textRange(from: start, to: end)
        }
    }
}

/// 路径条的材质层。
///
/// 路径条上是一行密排的小字，正下方又是不停滚动的目录名，材质透出来的残影会直接落在
/// 层级文字后面。这里**不再靠换一档更厚的材质**去压（那会让路径条成为一屏里唯一一块
/// 更浓的玻璃），改为在同一档磨砂上加厚画布色 tint：滚动时仍看得见内容在后面移动，
/// 但只剩一层化开的色块。Reduce Transparency 下退成等价实色。
private struct WorkspaceBrowsePathBarSurface: View {
    let tokens: ThemeTokens

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                Rectangle().fill(tokens.sidebarBackground)
            } else {
                Rectangle().fill(WorkbenchMaterial.surface)
                Rectangle().fill(tokens.sidebarBackground.opacity(0.62))
            }
        }
    }
}

/// 行按下的那一刻整行浮起一层浅底，抬指即落回：反馈跟着手指走，
/// 而不是等请求回来才有变化。
private struct WorkspaceBrowseRowButtonStyle: ButtonStyle {
    let tokens: ThemeTokens
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tokens.sidebarHoverFill)
                    .opacity(configuration.isPressed ? 1 : 0)
                    // 高亮比文字块略宽一点，读起来才是「整行被按下」而不是「文字被选中」。
                    .padding(.horizontal, -8)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 目录行：图标底板、名称、动作提示三段固定节奏。
///
/// 图标保持次级色重（accent 只属于工具栏那颗「打开」），但用一层中性底板托住，
/// 让长列表在快速滚动时有一条稳定的竖轴，而不是一列孤零零的灰线条。
private struct WorkspaceBrowseEntryRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    let entry: DirectoryEntry
    let isPreviewing: Bool
    /// 服务端已经说明这一项不能进入也不能预览时，整行降成静态信息，不再暗示可点。
    let isReachable: Bool

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(spacing: 12) {
            icon(tokens: tokens)
            Text(entry.name)
                .font(themeStore.uiFont(size: 15, weight: .medium))
                .foregroundStyle(isReachable ? tokens.primaryText : tokens.tertiaryText)
                // 目录名是唯一的辨识依据，长名折行而不是从中间截断。
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            accessory(tokens: tokens)
        }
        .padding(.vertical, 9)
        // 视觉收紧，命中区仍保持系统最小尺寸。
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    private func icon(tokens: ThemeTokens) -> some View {
        Image(systemName: entry.isDir ? "folder.fill" : "doc.text.fill")
            .font(themeStore.uiFont(size: 13, weight: .medium))
            .foregroundStyle(entry.isDir ? tokens.secondaryText : tokens.tertiaryText)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tokens.accentSoft)
            )
            .opacity(isReachable ? 1 : 0.5)
    }

    @ViewBuilder
    private func accessory(tokens: ThemeTokens) -> some View {
        if isPreviewing {
            ProgressView()
                .controlSize(.small)
        } else if !isReachable {
            EmptyView()
        } else {
            Image(systemName: entry.isDir ? "chevron.right" : "eye")
                .font(themeStore.uiFont(size: 12, weight: .semibold))
                .foregroundStyle(tokens.tertiaryText.opacity(0.6))
        }
    }
}

/// 目录选择器的位置指示改用面包屑路径条，而不是「上一级按钮 + 目录名 + 全路径」三段卡片。
///
/// 层级本身就是位置信息：轨迹可读出「我在哪」，省掉目录名与全路径的重复表达，
/// 也把只能单步回退的「上一级」升级为可直接跳到授权范围内的任意祖先层级。
/// 压缩后的首屏归还给真正的主任务——挑选目录。
struct WorkspaceCurrentDirectoryCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var themeStore: ThemeStore

    let path: String
    /// 服务端默认浏览根。它之上的层级会被 allowlist 直接拒绝，
    /// 所以那些段不能画成可点的面包屑，否则每次点击都换来一条 403。
    let rootPath: String?
    let parentPath: String?
    let isBrowsing: Bool
    let isOpening: Bool
    let onNavigate: (String) -> Void

    /// 每段的 id 用累积路径而非下标：路径前缀天然唯一，
    /// 目录切换时 SwiftUI 能按层级而不是位置对齐 diff。
    private struct PathCrumb: Identifiable {
        let name: String
        let path: String

        var id: String { path }
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let crumbs = visibleCrumbs

        let prefix = crumbs.first.flatMap(elidedPrefix(before:))

        return HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    if crumbs.isEmpty {
                        placeholderCrumb
                    } else {
                        if let prefix {
                            // 授权边界之上的层级不可进入，但绝对路径仍是确认位置的依据，
                            // 所以按原文保留成不可点的前缀，而不是压成一个省略号。
                            // 分隔符照常延续：这仍是一条连续路径，可点与否交给字色区分。
                            // 文件系统根只是首段的那一道斜杠，紧贴下一段，不单独占一格。
                            elidedPrefixLabel(prefix)
                            if prefix != "/" {
                                separator
                            }
                        }
                        ForEach(Array(crumbs.enumerated()), id: \.element.id) { index, crumb in
                            if index > 0 {
                                separator
                            }
                            crumbButton(
                                crumb,
                                isCurrent: index == crumbs.count - 1,
                                isLeading: index == 0 && (prefix == nil || prefix == "/")
                            )
                        }
                    }
                }
                .frame(minHeight: 44)
            }
            // 短路径贴左展示，深路径也从绝对路径起点开始；后半段留给用户向右滑动查看。
            .defaultScrollAnchor(.leading, for: .alignment)
            .defaultScrollAnchor(.leading, for: .initialOffset)

            if isBrowsing {
                // 进度留在路径条上，列表因此不必清空重画：位置指示本来就是这次跳转的主语。
                ProgressView()
                    .controlSize(.small)
                    .tint(tokens.tertiaryText)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isBrowsing)
    }

    @ViewBuilder
    private func crumbButton(_ crumb: PathCrumb, isCurrent: Bool, isLeading: Bool) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)

        if isCurrent {
            // 当前层级不是可点目标，用唯一一处 accent 承担「你在这里」，
            // 让列表行把 accent 让给真正的主动作（打开）。
            HStack(spacing: 5) {
                Image(systemName: "folder.fill")
                    .font(themeStore.uiFont(size: 12, weight: .semibold))
                    .accessibilityHidden(true)
                Text(crumb.name)
                    .font(themeStore.uiFont(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(tokens.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tokens.accentSoft, in: Capsule())
            .overlay {
                Capsule().strokeBorder(tokens.accent.opacity(0.16), lineWidth: 1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(crumb.name)
            .accessibilityValue(L10n.text("ui.current_location"))
        } else {
            // 能画成按钮的层级都已被 visibleCrumbs 过滤为服务端确实允许进入的，
            // 所以这里不存在“点了才发现不能点”的控件。
            let isParent = crumb.path == parentPath

            Button {
                onNavigate(crumb.path)
            } label: {
                Text(crumb.name)
                    .font(themeStore.uiFont(size: 14, weight: .medium))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
                    // 首段与列表的 16pt 内容边距对齐，之后各段留出 6pt 呼吸。
                    .padding(.leading, isLeading ? 0 : 6)
                    .padding(.trailing, 6)
                    // 视觉保持紧凑，命中区仍撑满路径条高度。
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
            .disabled(isBrowsing || isOpening)
            .accessibilityLabel(crumb.name)
            // 只有直接父级适用「返回上一级」；更高层级不给出会误导的提示。
            .accessibilityHint(isParent ? L10n.text("ui.return_to_previous_level") : "")
            // 直接父级沿用既有标识，其余层级按累积路径区分，避免同一轨迹里出现重复标识。
            .accessibilityIdentifier(
                isParent ? "workspace.open.parent" : "workspace.open.crumb.\(crumb.path)"
            )
        }
    }

    private var separator: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return Image(systemName: "chevron.compact.right")
            .font(themeStore.uiFont(size: 12, weight: .semibold))
            .foregroundStyle(tokens.tertiaryText.opacity(0.6))
            .accessibilityHidden(true)
    }

    private var placeholderCrumb: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return Text(L10n.text("ui.locating_be47409b"))
            .font(themeStore.uiFont(size: 14))
            .foregroundStyle(tokens.tertiaryText)
            .frame(minHeight: 44)
    }

    private func elidedPrefixLabel(_ prefix: String) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return Text(prefix)
            .font(themeStore.uiFont(size: 14))
            .foregroundStyle(tokens.tertiaryText)
            .lineLimit(1)
            .padding(.trailing, prefix == "/" ? 0 : 6)
            // 不可点，但作为静态文本保留给 VoiceOver，补充授权边界以上的路径信息。
    }

    /// 首个可见层级之上被裁掉的那段绝对路径，没有则返回 nil。
    /// 文件系统根返回 "/"：路径条要始终读得出这是一条绝对路径。
    private func elidedPrefix(before crumb: PathCrumb) -> String? {
        guard crumb.path != "/" else { return nil }
        let prefix = (crumb.path as NSString).deletingLastPathComponent
        return prefix.isEmpty ? nil : prefix
    }

    /// 只保留授权边界之内的层级。
    ///
    /// 边界下沿取「默认浏览根」与服务端明确给出的 `parentPath` 中较浅的一个：
    /// 前者由首次浏览学到，后者已由服务端确认可进入（可能略高于浏览根）。
    /// 两者都不在轨迹里时说明已到边界顶，只显示当前层级。
    private var visibleCrumbs: [PathCrumb] {
        let crumbs = pathCrumbs
        guard !crumbs.isEmpty else { return [] }

        let boundaries = Set([rootPath, parentPath].compactMap { $0 })
        guard let floor = crumbs.first(where: { boundaries.contains($0.path) }) else {
            return [crumbs[crumbs.count - 1]]
        }
        return Array(crumbs.drop(while: { $0.path != floor.path }))
    }

    private var pathCrumbs: [PathCrumb] {
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty || path == "/" else { return [] }

        // 先构造完整轨迹（含文件系统根），再由 visibleCrumbs 按授权边界裁掉上层。
        var crumbs: [PathCrumb] = path.hasPrefix("/") ? [PathCrumb(name: "/", path: "/")] : []
        var accumulated = ""
        for component in components {
            accumulated += "/" + component
            crumbs.append(PathCrumb(name: component, path: accumulated))
        }
        return crumbs
    }
}

struct WorkspaceOpenCurrentDirectoryToolbarButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    let isOpening: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Button(action: action) {
            if isOpening {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tokens.primaryActionForeground)
                    Text(L10n.text("ui.opening"))
                }
            } else {
                Text(L10n.text("ui.open"))
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(tokens.primaryAction)
        .foregroundStyle(tokens.primaryActionForeground)
        .fixedSize(horizontal: true, vertical: false)
        .frame(minWidth: 44, minHeight: 44)
        .disabled(isDisabled)
        .accessibilityLabel(isOpening ? L10n.text("ui.opening_workspace") : L10n.text("ui.open"))
        .accessibilityIdentifier("workspace.open.current")
    }
}

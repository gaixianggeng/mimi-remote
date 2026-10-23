import SwiftUI

/// iPad 外接键盘的会话级快捷键（#828）。
///
/// 动作由工作台外壳通过 `focusedSceneValue` 提供，菜单项注册在 Scene 的 `commands` 里，
/// 因此会出现在 iPadOS 菜单栏和按住 ⌘ 时的快捷键面板中。输入框自己的快捷键
/// （⌘↩ 发送、⌘K 添加内容、⌘⇧D 语音等）仍由输入框注册，这里不重复。
struct WorkbenchCommandActions {
    struct SidebarShortcut: Equatable, Identifiable {
        let id: SessionID
        let title: String
    }

    /// 侧栏「待你处理 / 进行中 / 刚完成 / 置顶 / 最近」按显示顺序的前 9 条，对应 ⌘1～⌘9。
    var sidebarShortcuts: [SidebarShortcut]
    var openJumpPanel: () -> Void
    var openSession: (SessionID) -> Void
    var newSession: () -> Void
    /// 只有当前看着的会话正在运行且可控制时才提供；否则菜单项置灰。
    var stopCurrentReply: (() -> Void)?
    var goBack: (() -> Void)?
    var goForward: (() -> Void)?
}

private struct WorkbenchCommandActionsKey: FocusedValueKey {
    typealias Value = WorkbenchCommandActions
}

extension FocusedValues {
    var workbenchCommands: WorkbenchCommandActions? {
        get { self[WorkbenchCommandActionsKey.self] }
        set { self[WorkbenchCommandActionsKey.self] = newValue }
    }
}

struct WorkbenchSessionCommands: Commands {
    @FocusedValue(\.workbenchCommands) private var actions

    var body: some Commands {
        CommandMenu(L10n.text("ui.keyboard_menu_sessions")) {
            Button(L10n.text("ui.go_to_session")) { actions?.openJumpPanel() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(actions == nil)
            Button(L10n.text("ui.search_session")) { actions?.openJumpPanel() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions == nil)
            Button(L10n.text("ui.new_session_3da224c4")) { actions?.newSession() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(actions == nil)

            Divider()

            Button(L10n.text("ui.stop_current_reply")) { actions?.stopCurrentReply?() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(actions?.stopCurrentReply == nil)

            Divider()

            Button(L10n.text("ui.previous_session")) { actions?.goBack?() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(actions?.goBack == nil)
            Button(L10n.text("ui.next_session")) { actions?.goForward?() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(actions?.goForward == nil)

            if let shortcuts = actions?.sidebarShortcuts, !shortcuts.isEmpty {
                Divider()
                ForEach(Array(shortcuts.prefix(9).enumerated()), id: \.element.id) { index, shortcut in
                    Button(shortcut.title) { actions?.openSession(shortcut.id) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
            }
        }
    }
}

/// ⌘[ / ⌘] 在最近打开过的会话之间前进、后退，语义与浏览器历史一致。
struct WorkbenchSessionHistory: Equatable {
    static let limit = 30

    private(set) var backStack: [SessionID] = []
    private(set) var forwardStack: [SessionID] = []
    private(set) var current: SessionID?

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// 打开新会话：当前会话进入后退栈，前进栈清空。重复打开同一会话不记录。
    mutating func visit(_ id: SessionID) {
        guard id != current else {
            return
        }
        if let current {
            backStack.removeAll { $0 == id }
            backStack.append(current)
            if backStack.count > Self.limit {
                backStack.removeFirst(backStack.count - Self.limit)
            }
        }
        current = id
        forwardStack.removeAll()
    }

    /// 返回上一个仍然存在的会话；已删除或已归档的会话直接跳过。
    mutating func goBack(isAvailable: (SessionID) -> Bool) -> SessionID? {
        var source = backStack
        var destination = forwardStack
        let target = Self.step(from: &source, to: &destination, current: current, isAvailable: isAvailable)
        backStack = source
        forwardStack = destination
        if let target { current = target }
        return target
    }

    mutating func goForward(isAvailable: (SessionID) -> Bool) -> SessionID? {
        var source = forwardStack
        var destination = backStack
        let target = Self.step(from: &source, to: &destination, current: current, isAvailable: isAvailable)
        forwardStack = source
        backStack = destination
        if let target { current = target }
        return target
    }

    /// 会话 ID 被服务端替换（例如草稿转正式会话）时同步改写历史，避免后退到失效 ID。
    mutating func replace(_ oldID: SessionID, with newID: SessionID) {
        backStack = backStack.map { $0 == oldID ? newID : $0 }
        forwardStack = forwardStack.map { $0 == oldID ? newID : $0 }
        if current == oldID {
            current = newID
        }
    }

    private static func step(
        from source: inout [SessionID],
        to destination: inout [SessionID],
        current: SessionID?,
        isAvailable: (SessionID) -> Bool
    ) -> SessionID? {
        while let candidate = source.popLast() {
            guard isAvailable(candidate), candidate != current else {
                continue
            }
            if let current {
                destination.append(current)
            }
            return candidate
        }
        return nil
    }
}

extension SessionSidebarSectionKind {
    var localizedTitle: String {
        switch self {
        case .needYou:
            return L10n.text("ui.needs_you")
        case .running:
            return L10n.text("ui.in_progress")
        case .justCompleted:
            return L10n.text("ui.just_completed")
        case .pinned:
            return L10n.text("ui.pinned")
        case .recent:
            return L10n.text("ui.recently")
        }
    }
}

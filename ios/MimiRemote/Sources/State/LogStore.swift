import Foundation

@MainActor
final class LogStore: ObservableObject {
    @Published private var activeProfileID = ""
    @Published private var visibleLogsByScopedSession: [ScopedSessionID: String] = [:]
    // 已渲染的日志行：在后台线程算好再发布，避免 LogPanelView 在 body 里对 8 万字符做 split+正则。
    @Published private var renderedLinesByScopedSession: [ScopedSessionID: [LogDisplayLine]] = [:]
    @Published var autoScroll = true

    private var buffers: [ScopedSessionID: String] = [:]
    private var bufferStartLineBySessionID: [ScopedSessionID: Int] = [:]
    private var pendingChunks: [ScopedSessionID: [String]] = [:]
    private var pendingChunkCharacters: [ScopedSessionID: Int] = [:]
    private var flushTasks: [ScopedSessionID: Task<Void, Never>] = [:]
    private var lastSeenSeqBySessionID: [ScopedSessionID: EventSequence] = [:]
    private var sessionAccessTickBySessionID: [ScopedSessionID: UInt64] = [:]
    private var sessionAccessCounter: UInt64 = 0
    private let maxPendingCharacters = 160_000
    private let maxBufferCharacters = 120_000
    private let maxVisibleCharacters = 80_000
    private let flushDelayNanoseconds: UInt64 = 120_000_000
    static let retainedSessionLimit = 16

    /// 切换主机只替换当前命名空间，不复制或清空缓存；所有主机继续共享同一组 LRU 上限。
    func activate(profileID: String) {
        guard activeProfileID != profileID else {
            return
        }
        activeProfileID = profileID
    }

    /// 删除档案时清掉该 Profile 的原始缓冲、渲染结果和延迟 flush Task。
    func remove(profileID: String) {
        for (scopedSessionID, task) in flushTasks where scopedSessionID.profileID == profileID {
            task.cancel()
        }
        flushTasks = flushTasks.filter { $0.key.profileID != profileID }
        pendingChunks = pendingChunks.filter { $0.key.profileID != profileID }
        pendingChunkCharacters = pendingChunkCharacters.filter { $0.key.profileID != profileID }
        buffers = buffers.filter { $0.key.profileID != profileID }
        bufferStartLineBySessionID = bufferStartLineBySessionID.filter { $0.key.profileID != profileID }
        visibleLogsByScopedSession = visibleLogsByScopedSession.filter { $0.key.profileID != profileID }
        renderedLinesByScopedSession = renderedLinesByScopedSession.filter { $0.key.profileID != profileID }
        lastSeenSeqBySessionID = lastSeenSeqBySessionID.filter { $0.key.profileID != profileID }
        sessionAccessTickBySessionID = sessionAccessTickBySessionID.filter { $0.key.profileID != profileID }
    }

    func log(for sessionID: String?) -> String {
        guard let sessionID else {
            return ""
        }
        let scopedSessionID = scopedSessionID(for: sessionID)
        return visibleLogsByScopedSession[scopedSessionID] ?? buffers[scopedSessionID] ?? ""
    }

    /// 导出读取已完成 ANSI 清洗的当前内存缓存窗口（最多 12 万字符），而不是 UI 的 8 万字符可见窗口。
    /// 这是设备侧诊断窗口，不代表服务端完整历史。
    /// 尚在 120ms 合并队列中的原始分片不会同步阻塞主线程；下一次 flush 后即可进入导出窗口。
    func cachedLogForExport(for sessionID: String?) -> String {
        guard let sessionID else {
            return ""
        }
        let scopedSessionID = scopedSessionID(for: sessionID)
        return buffers[scopedSessionID] ?? visibleLogsByScopedSession[scopedSessionID] ?? ""
    }

    func lines(for sessionID: String?) -> [LogDisplayLine] {
        guard let sessionID else {
            return []
        }
        return renderedLinesByScopedSession[scopedSessionID(for: sessionID)] ?? []
    }

    func lastSeq(for sessionID: String?) -> EventSequence? {
        guard let sessionID else {
            return nil
        }
        return lastSeenSeqBySessionID[scopedSessionID(for: sessionID)]
    }

    func retainSessionCache(sessionID: String) {
        let scopedSessionID = scopedSessionID(for: sessionID)
        guard hasCacheState(scopedSessionID: scopedSessionID) else {
            return
        }
        touchLogSession(scopedSessionID)
    }

    func append(_ chunk: String, sessionID: String, seq: EventSequence? = nil) {
        guard !chunk.isEmpty else {
            return
        }
        let scopedSessionID = scopedSessionID(for: sessionID)
        guard shouldAccept(seq: seq, scopedSessionID: scopedSessionID) else {
            return
        }

        // 日志只维护自己的缓冲区；输入框和对话解析都不会反向触发这里。
        pendingChunks[scopedSessionID, default: []].append(chunk)
        pendingChunkCharacters[scopedSessionID, default: 0] += chunk.count
        trimPendingChunksIfNeeded(scopedSessionID: scopedSessionID)
        touchLogSession(scopedSessionID)
        trimLogSessionCachesIfNeeded()
        scheduleFlush(scopedSessionID: scopedSessionID)
    }

    func reset(sessionID: String) {
        clearLogSessionState(scopedSessionID: scopedSessionID(for: sessionID), publishEmptyState: true)
    }

    private func shouldAccept(seq: EventSequence?, scopedSessionID: ScopedSessionID) -> Bool {
        guard let seq else {
            return true
        }
        if let last = lastSeenSeqBySessionID[scopedSessionID], seq <= last {
            return false
        }
        // 结构化日志可能在重连后 bounded replay；按 Codex/Litter 的单调 seq 思路，
        // Store 层先做轻量去重，避免旧块再次触发布局和行解析。
        lastSeenSeqBySessionID[scopedSessionID] = seq
        return true
    }

    private func scheduleFlush(scopedSessionID: ScopedSessionID) {
        guard flushTasks[scopedSessionID] == nil else {
            return
        }
        let delay = flushDelayNanoseconds
        // Task 捕获不可变 scoped key；主机切换后只能回写原 Profile，不能按新的 activeProfileID 重算。
        flushTasks[scopedSessionID] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }

            // 取出待清洗的原始分片（主线程，仅做缓冲区搬运）。
            let raw = await MainActor.run { [weak self] () -> String in
                guard let self else {
                    return ""
                }
                let joined = self.pendingChunks[scopedSessionID, default: []].joined()
                self.pendingChunks[scopedSessionID] = []
                self.pendingChunkCharacters[scopedSessionID] = 0
                return joined
            }

            // ANSI 清洗可能要扫一大段终端控制序列，放到后台线程，避免每 120ms 卡主线程。
            let chunk = await Task.detached(priority: .utility) {
                AnsiCleaner.clean(raw)
            }.value
            guard !Task.isCancelled else {
                return
            }

            // 追加缓冲并取出最新可见窗口（主线程，仅做字符串搬运）。
            let visibleSnapshot = await MainActor.run { [weak self] () -> (text: String, startLineID: Int) in
                guard let self else {
                    return ("", 0)
                }
                if !chunk.isEmpty {
                    let current = (self.buffers[scopedSessionID] ?? "") + chunk
                    let trimmed = self.trimmedLogBuffer(current, scopedSessionID: scopedSessionID)
                    self.buffers[scopedSessionID] = trimmed
                }
                let visible = self.visibleLogWindow(scopedSessionID: scopedSessionID)
                self.setVisibleLogIfChanged(visible, scopedSessionID: scopedSessionID)
                return (visible, self.visibleStartLineID(scopedSessionID: scopedSessionID, visible: visible))
            }

            // 行解析（split + 逐行正则 + 去噪）是最重的一步，放到后台线程算好再发布。
            let lines = await Task.detached(priority: .utility) {
                LogPanelFormatter().renderedLines(from: visibleSnapshot.text, startLineID: visibleSnapshot.startLineID)
            }.value
            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                guard let self else {
                    return
                }
                self.setRenderedLinesIfChanged(lines, scopedSessionID: scopedSessionID)
                self.flushTasks[scopedSessionID] = nil
                // 后台处理期间可能又有分片落入 pendingChunks，补一次调度避免漏刷。
                if self.pendingChunks[scopedSessionID]?.isEmpty == false {
                    self.scheduleFlush(scopedSessionID: scopedSessionID)
                }
            }
        }
    }

    private func setVisibleLogIfChanged(_ visible: String, scopedSessionID: ScopedSessionID) {
        guard visibleLogsByScopedSession[scopedSessionID] != visible else {
            return
        }
        visibleLogsByScopedSession[scopedSessionID] = visible
    }

    private func setRenderedLinesIfChanged(_ lines: [LogDisplayLine], scopedSessionID: ScopedSessionID) {
        guard renderedLinesByScopedSession[scopedSessionID] != lines else {
            return
        }
        renderedLinesByScopedSession[scopedSessionID] = lines
    }

    private func trimmedLogBuffer(_ current: String, scopedSessionID: ScopedSessionID) -> String {
        guard current.count > maxBufferCharacters else {
            return current
        }
        let dropCount = current.count - maxBufferCharacters
        let dropIndex = current.index(current.startIndex, offsetBy: dropCount)
        let droppedPrefix = current[..<dropIndex]
        // 缓冲区裁剪时累加被丢弃的换行数，后续渲染行继续使用绝对行号，避免 SwiftUI 把尾部行全部当成新行。
        bufferStartLineBySessionID[scopedSessionID, default: 0] += newlineCount(in: droppedPrefix)
        return String(current[dropIndex...])
    }

    private func visibleLogWindow(scopedSessionID: ScopedSessionID) -> String {
        let buffer = buffers[scopedSessionID] ?? ""
        guard buffer.count > maxVisibleCharacters else {
            return buffer
        }
        return String(buffer.suffix(maxVisibleCharacters))
    }

    private func visibleStartLineID(scopedSessionID: ScopedSessionID, visible: String) -> Int {
        let buffer = buffers[scopedSessionID] ?? ""
        var startLineID = bufferStartLineBySessionID[scopedSessionID] ?? 0
        guard buffer.count > visible.count else {
            return startLineID
        }
        let dropCount = buffer.count - visible.count
        let dropIndex = buffer.index(buffer.startIndex, offsetBy: dropCount)
        startLineID += newlineCount(in: buffer[..<dropIndex])
        return startLineID
    }

    private func newlineCount<S: StringProtocol>(in text: S) -> Int {
        text.reduce(0) { count, character in
            character == "\n" ? count + 1 : count
        }
    }

    private func hasCacheState(scopedSessionID: ScopedSessionID) -> Bool {
        buffers[scopedSessionID] != nil
            || visibleLogsByScopedSession[scopedSessionID] != nil
            || renderedLinesByScopedSession[scopedSessionID] != nil
            || pendingChunks[scopedSessionID]?.isEmpty == false
            || pendingChunkCharacters[scopedSessionID, default: 0] > 0
            || lastSeenSeqBySessionID[scopedSessionID] != nil
    }

    private func trimPendingChunksIfNeeded(scopedSessionID: ScopedSessionID) {
        guard let total = pendingChunkCharacters[scopedSessionID],
              total > maxPendingCharacters,
              let chunks = pendingChunks[scopedSessionID]
        else {
            return
        }

        let trimmed = trimPendingChunkWindow(chunks: chunks, total: total, maxCharacters: maxPendingCharacters)
        pendingChunks[scopedSessionID] = trimmed.chunks
        pendingChunkCharacters[scopedSessionID] = trimmed.total
    }

    private func trimPendingChunkWindow(
        chunks: [String],
        total: Int,
        maxCharacters: Int
    ) -> (chunks: [String], total: Int) {
        var overflow = total - maxCharacters
        guard overflow > 0 else {
            return (chunks, total)
        }
        var keptTotal = total
        var firstKeptIndex = 0

        // 后台清洗/渲染慢于输出时，未 flush 队列也必须有界；保留尾部最新输出。
        // 这里参考 Litter 的 bounded queue 思路：一次扫描定位保留窗口，避免 removeFirst
        // 在大量小分片积压时反复搬数组。
        while firstKeptIndex < chunks.count {
            let chunkCount = chunks[firstKeptIndex].count
            if chunkCount > overflow {
                break
            }
            overflow -= chunkCount
            keptTotal -= chunkCount
            firstKeptIndex += 1
        }

        var keptChunks: [String] = []
        keptChunks.reserveCapacity(chunks.count - firstKeptIndex)
        if firstKeptIndex < chunks.count {
            let firstKept = chunks[firstKeptIndex]
            if overflow > 0 {
                let keepCount = firstKept.count - overflow
                let keepStart = firstKept.index(firstKept.endIndex, offsetBy: -keepCount)
                keptChunks.append(String(firstKept[keepStart...]))
                keptTotal -= overflow
                firstKeptIndex += 1
            }
            if firstKeptIndex < chunks.count {
                keptChunks.append(contentsOf: chunks[firstKeptIndex...])
            }
        }

        return (keptChunks, keptTotal)
    }

    private func touchLogSession(_ scopedSessionID: ScopedSessionID) {
        // 日志分片可能高频到达；touch 只更新时间戳，避免数组 firstIndex/removeFirst 在多会话下反复搬移。
        sessionAccessCounter &+= 1
        sessionAccessTickBySessionID[scopedSessionID] = sessionAccessCounter
    }

    private func trimLogSessionCachesIfNeeded() {
        // 日志缓存比对话缓存更重（原始缓冲、可见窗口、渲染行各一份）。
        // 参考 Codex/Litter 的有界状态思路，只保留最近访问的会话，避免长期运行后内存线性增长。
        while sessionAccessTickBySessionID.count > Self.retainedSessionLimit,
              let oldest = sessionAccessTickBySessionID.min(by: { $0.value < $1.value }) {
            clearLogSessionState(scopedSessionID: oldest.key, publishEmptyState: false)
        }
    }

    private func clearLogSessionState(scopedSessionID: ScopedSessionID, publishEmptyState: Bool) {
        flushTasks[scopedSessionID]?.cancel()
        flushTasks[scopedSessionID] = nil
        pendingChunks[scopedSessionID] = publishEmptyState ? [] : nil
        pendingChunkCharacters[scopedSessionID] = nil
        buffers[scopedSessionID] = publishEmptyState ? "" : nil
        bufferStartLineBySessionID[scopedSessionID] = publishEmptyState ? 0 : nil
        visibleLogsByScopedSession[scopedSessionID] = publishEmptyState ? "" : nil
        renderedLinesByScopedSession[scopedSessionID] = publishEmptyState ? [] : nil
        lastSeenSeqBySessionID[scopedSessionID] = nil
        sessionAccessTickBySessionID[scopedSessionID] = nil
    }

    private func scopedSessionID(for sessionID: String) -> ScopedSessionID {
        ScopedSessionID(profileID: activeProfileID, sessionID: sessionID)
    }

}

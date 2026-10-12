import Foundation

struct FileUploadResponse: Decodable, Hashable {
    let uploadID: String
    let name: String
    let contentType: String
    let size: Int64
    let sha256: String
    let createdAt: Date
    let expiresAt: Date
    let downloadPath: String

    enum CodingKeys: String, CodingKey {
        case uploadID = "upload_id"
        case name
        case contentType = "content_type"
        case size
        case sha256
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case downloadPath = "download_path"
    }
}

enum FileUploadPhase: Equatable {
    case preparing
    case uploading
    case failed
}

struct FileUploadJob: Identifiable, Equatable {
    let id: UUID
    let targetScope: ComposerDraftScopeKey
    var fileName: String
    var phase: FileUploadPhase
    var progress: Double
    var errorMessage: String?
    var canRetry: Bool
}

enum MobileFileUploadError: LocalizedError, Equatable {
    case serverUnsupported
    case locallyDisabled
    case dependencyUnavailable
    case negotiationFailed
    case hostChanged

    var errorDescription: String? {
        switch self {
        case .serverUnsupported:
            return L10n.text("ui.current_mac_version_does_not_support_file_upload")
        case .locallyDisabled:
            return L10n.text("ui.file_upload_disabled_on_current_mac")
        case .dependencyUnavailable:
            return L10n.text("ui.file_upload_dependency_unavailable_on_current_mac")
        case .negotiationFailed:
            return L10n.text("ui.file_upload_capability_negotiation_failed")
        case .hostChanged:
            return L10n.text("ui.file_upload_host_changed_select_again")
        }
    }

    init(decision: HostCapabilityDecision) {
        switch decision {
        case .enabled:
            self = .negotiationFailed
        case .serverUnsupported:
            self = .serverUnsupported
        case .locallyDisabled:
            self = .locallyDisabled
        case .dependencyUnavailable:
            self = .dependencyUnavailable
        case .negotiationFailed:
            self = .negotiationFailed
        }
    }
}

@MainActor
final class FileUploadStore: ObservableObject {
    typealias Completion = @MainActor (UploadedFileAttachment, ComposerDraftScopeKey) -> Void

    @Published private(set) var jobs: [FileUploadJob] = []

    private struct Context {
        let sourceURL: URL
        let targetScope: ComposerDraftScopeKey
        let endpoint: String
        let token: String
        let idempotencyKey: String
        let completion: Completion
        var prepared: PreparedFileUpload?
    }

    private let session: URLSession
    private var contexts: [UUID: Context] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    func start(
        selectedURL: URL,
        targetScope: ComposerDraftScopeKey,
        endpoint: String,
        token: String,
        completion: @escaping Completion
    ) {
        guard targetScope != .none else {
            return
        }
        let id = UUID()
        let displayName = selectedURL.lastPathComponent.isEmpty
            ? L10n.text("ui.file")
            : selectedURL.lastPathComponent
        jobs.append(FileUploadJob(
            id: id,
            targetScope: targetScope,
            fileName: displayName,
            phase: .preparing,
            progress: 0,
            errorMessage: nil,
            canRetry: false
        ))
        contexts[id] = Context(
            sourceURL: selectedURL,
            targetScope: targetScope,
            endpoint: endpoint,
            token: token,
            idempotencyKey: UUID().uuidString,
            completion: completion,
            prepared: nil
        )
        run(id: id)
    }

    func retry(id: UUID) {
        guard contexts[id] != nil,
              let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].phase == .failed
        else {
            return
        }
        jobs[index].phase = contexts[id]?.prepared == nil ? .preparing : .uploading
        jobs[index].progress = 0
        jobs[index].errorMessage = nil
        jobs[index].canRetry = false
        run(id: id)
    }

    func cancel(id: UUID) {
        tasks[id]?.cancel()
        tasks.removeValue(forKey: id)
        contexts.removeValue(forKey: id)?.prepared?.removeStagingFiles()
        jobs.removeAll { $0.id == id }
    }

    /// 连接切换时必须把旧主机的上传状态作为一个整体失效。
    /// Context 捕获了旧 endpoint/token；若仅清草稿，迟到回调仍可能写入新主机的同名会话。
    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        contexts.values.forEach { $0.prepared?.removeStagingFiles() }
        contexts.removeAll()
        jobs.removeAll()
    }

    func jobs(for scope: ComposerDraftScopeKey) -> [FileUploadJob] {
        jobs.filter { $0.targetScope == scope }
    }

    func hasBlockingJob(for scope: ComposerDraftScopeKey) -> Bool {
        jobs.contains { $0.targetScope == scope }
    }

    private func run(id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = Task { [weak self] in
            await self?.perform(id: id)
        }
    }

    private func perform(id: UUID) async {
        guard var context = contexts[id] else {
            return
        }
        do {
            let prepared: PreparedFileUpload
            if let existing = context.prepared {
                prepared = existing
            } else {
                prepared = try await FileAttachmentPreparer.prepare(selectedURL: context.sourceURL)
                if Task.isCancelled {
                    // 预处理可能在线程取消后才返回；此时 Context 已被清理，必须在这里
                    // 主动删除刚创建的私有 staging，不能依赖失败重试路径。
                    prepared.removeStagingFiles()
                    throw CancellationError()
                }
                context.prepared = prepared
                contexts[id] = context
            }
            updateJob(id: id) {
                $0.fileName = prepared.name
                $0.phase = .uploading
                $0.progress = 0
            }

            let response = try await FileUploadTransport(session: session).upload(
                file: prepared,
                endpoint: context.endpoint,
                token: context.token,
                idempotencyKey: context.idempotencyKey
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.updateJob(id: id) {
                        $0.phase = .uploading
                        $0.progress = min(max(progress, 0), 1)
                    }
                }
            }
            try Task.checkCancellation()
            let attachment = UploadedFileAttachment(
                uploadID: response.uploadID,
                name: response.name,
                contentType: response.contentType,
                size: response.size,
                sha256: response.sha256,
                downloadPath: response.downloadPath,
                createdAt: response.createdAt,
                expiresAt: response.expiresAt,
                extractedText: prepared.extractedText,
                pageImageDataURLs: prepared.pageImageDataURLs
            )
            context.completion(attachment, context.targetScope)
            prepared.removeStagingFiles()
            contexts.removeValue(forKey: id)
            tasks.removeValue(forKey: id)
            jobs.removeAll { $0.id == id }
        } catch {
            guard contexts[id] != nil else {
                return
            }
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                cancel(id: id)
                return
            }
            tasks.removeValue(forKey: id)
            updateJob(id: id) {
                $0.phase = .failed
                $0.errorMessage = UserFacingError(error).message
                // 用户主动选择的 URL 在本次编辑期间仍然有效，预处理与网络失败都允许原地重试。
                $0.canRetry = true
            }
        }
    }

    private func updateJob(id: UUID, _ update: (inout FileUploadJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }
        update(&jobs[index])
    }
}

private struct FileUploadTransport {
    let session: URLSession

    func upload(
        file: PreparedFileUpload,
        endpoint: String,
        token: String,
        idempotencyKey: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> FileUploadResponse {
        let baseURL = try EndpointTransportPolicy.validatedURL(endpoint)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AgentAPIError.invalidEndpoint
        }
        components.path = "/api/file-uploads"
        guard let url = components.url else {
            throw AgentAPIError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        MimiProtocolContract.applyClientHeaders(to: &request)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.setValue(Self.base64URL(file.name), forHTTPHeaderField: "X-Mimi-File-Name")

        let box = FileUploadTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.uploadTask(with: request, fromFile: file.fileURL) { data, response, error in
                    box.clear()
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        continuation.resume(throwing: AgentAPIError.invalidResponse)
                        return
                    }
                    let data = data ?? Data()
                    guard (200..<300).contains(http.statusCode) else {
                        let message = Self.decodeError(data)
                        if AgentAPIError.isCredentialRejection(
                            status: http.statusCode,
                            message: message,
                            authenticationChallenge: http.value(forHTTPHeaderField: "WWW-Authenticate")
                        ) {
                            continuation.resume(throwing: AgentAPIError.credentialsInvalid(
                                status: http.statusCode,
                                credentialFingerprint: connectionCredentialFingerprint(token)
                            ))
                        } else {
                            continuation.resume(throwing: AgentAPIError.server(status: http.statusCode, message: message))
                        }
                        return
                    }
                    do {
                        continuation.resume(returning: try AgentAPIClient.decoder.decode(FileUploadResponse.self, from: data))
                    } catch {
                        continuation.resume(throwing: AgentAPIError.decoding(error))
                    }
                }
                let observation = task.progress.observe(\.fractionCompleted, options: [.initial, .new]) { value, _ in
                    progress(value.fractionCompleted)
                }
                box.install(task: task, observation: observation)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    private static func base64URL(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeError(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? String {
            return error
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? L10n.text("ui.unknown_error")
    }
}

private final class FileUploadTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionUploadTask?
    private var observation: NSKeyValueObservation?
    private var isCancelled = false

    func install(task: URLSessionUploadTask, observation: NSKeyValueObservation) {
        lock.lock()
        self.task = task
        self.observation = observation
        let shouldCancel = isCancelled
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func clear() {
        lock.lock()
        observation?.invalidate()
        observation = nil
        task = nil
        isCancelled = false
        lock.unlock()
    }
}

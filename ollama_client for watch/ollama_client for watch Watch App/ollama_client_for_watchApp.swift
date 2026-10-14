//
//  ollama_client_for_watchApp.swift
//  ollama_client for watch Watch App
//
//  在 Apple Watch 上连接内网 Ollama / 兼容 OpenAI Chat Completions 的服务并对话。
//  单一文件实现，编译目标 watchOS 26.x / Swift 5.0（strict concurrency，MainActor 隔离）。
//

import SwiftUI
import Foundation
import Combine        // @Published / ObservableObject
import os.log         // 日志（替代 print，方便用 simctl log show 抓到）
// 注：watchOS 不暴露 UIPasteboard / TextEditor / Menu / textSelection / keyboardType，用适配方案替代。

let log = Logger(subsystem: "test2.xin.ollama-client-for-watch", category: "app")

// MARK: - 0. 全局配置 / 工具

extension URLSession {
    /// 适合手表的默认网络配置：30 秒请求超时，2 分钟资源超时，自动等待网络恢复。
    static let ollamaDefault: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 120
        cfg.waitsForConnectivity = true
        cfg.allowsCellularAccess = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()
}

extension String {
    /// 去掉首尾空白，并把末尾所有 `/` 去掉，但保留协议里的 `//`。
    var trimmedForURL: String {
        var s = self.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

enum OllamaError: LocalizedError, Equatable {
    case invalidURL
    case http(Int, String?)
    case decoding(String)
    case stream(String)
    case timeout
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL:       return "服务器地址格式有误"
        case .http(let code, _):return "服务器返回 HTTP \(code)"
        case .decoding(let s):  return "解析失败：\(s)"
        case .stream(let s):    return "流式中断：\(s)"
        case .timeout:          return "请求超时，请检查网络或服务器"
        case .cancelled:        return "已取消"
        }
    }
}

// MARK: - 1. 数据模型

enum ChatRole: String, Codable, Sendable {
    case system
    case user
    case assistant
}

struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var role: ChatRole
    var content: String
    var timestamp: Date
    /// 是否正在流式输出（用于显示光标），不参与持久化。
    var isStreaming: Bool

    init(id: UUID = UUID(),
         role: ChatRole,
         content: String,
         timestamp: Date = Date(),
         isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
    }

    enum CodingKeys: String, CodingKey { case id, role, content, timestamp }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.role = try c.decode(ChatRole.self, forKey: .role)
        self.content = try c.decode(String.self, forKey: .content)
        self.timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        self.isStreaming = false
    }
}

struct ChatSession: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var messages: [ChatMessage]
    var createdAt: Date
    var updatedAt: Date
    var systemPrompt: String

    init(id: UUID = UUID(),
         title: String = "新对话",
         messages: [ChatMessage] = [],
         systemPrompt: String = "") {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = Date()
        self.updatedAt = Date()
        self.systemPrompt = systemPrompt
    }
}

// MARK: - 2. 网络层（Ollama 原生协议 + 兼容 OpenAI）

/// Ollama 协议响应模型
struct OllamaTagsResponse: Codable, Sendable {
    struct ModelTag: Codable, Hashable, Sendable {
        let name: String
        let size: Int64?
        let modified_at: Date?
        let digest: String?
    }
    let models: [ModelTag]
}

struct OllamaChatResponse: Codable, Sendable {
    struct Message: Codable, Sendable {
        let role: String
        let content: String
    }
    let message: Message
    let done: Bool?
}

/// 流式响应里的单行 JSON
struct OllamaChatChunk: Codable, Sendable {
    struct Message: Codable, Sendable {
        let role: String?
        let content: String?
    }
    let model: String?
    let message: Message?
    let done: Bool?
    let error: String?
}

/// 纯网络层。`Sendable` struct，不持有可变状态。
struct OllamaClient: Sendable {
    let baseURL: URL
    let session: URLSession

    init(baseURL: URL, session: URLSession = .ollamaDefault) {
        self.baseURL = baseURL
        self.session = session
    }

    // 健康检查：GET /
    func health() async throws {
        let url = baseURL
        do {
            let (_, resp) = try await session.data(from: url)
            try Self.ensureOK(resp)
        } catch let e as URLError where e.code == .timedOut {
            throw OllamaError.timeout
        }
    }

    /// 获取模型列表
    func fetchModels() async throws -> [OllamaTagsResponse.ModelTag] {
        let url = baseURL.appendingPathComponent("api/tags")
        let (data, resp) = try await session.data(from: url)
        try Self.ensureOK(resp)
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(OllamaTagsResponse.self, from: data).models
        } catch {
            throw OllamaError.decoding(error.localizedDescription)
        }
    }

    /// 单次请求（不流式），用于健康检查、轻量调用
    func chatOnce(model: String,
                  messages: [ChatMessage],
                  systemPrompt: String) async throws -> String {
        let url = baseURL.appendingPathComponent("api/chat")
        let payload = makePayload(model: model, messages: messages, systemPrompt: systemPrompt, stream: false)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await session.data(for: req)
        try Self.ensureOK(resp)
        do {
            let r = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
            return r.message.content
        } catch {
            throw OllamaError.decoding(error.localizedDescription)
        }
    }

    /// 流式聊天：逐 token 把增量内容通过 `onChunk` 推送给 MainActor。
    /// 调用方负责在 MainActor 上更新 UI。
    func streamChat(model: String,
                    messages: [ChatMessage],
                    systemPrompt: String,
                    onChunk: @escaping @MainActor (String) -> Void) async throws {
        let url = baseURL.appendingPathComponent("api/chat")
        let payload = makePayload(model: model, messages: messages, systemPrompt: systemPrompt, stream: true)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, resp) = try await session.bytes(for: req)
        try Self.ensureOK(resp)

        // 逐行读取 NDJSON
        for try await line in bytes.lines {
            if Task.isCancelled { throw OllamaError.cancelled }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8) else { continue }
            if let chunk = try? JSONDecoder().decode(OllamaChatChunk.self, from: data) {
                if let err = chunk.error { throw OllamaError.stream(err) }
                if let token = chunk.message?.content, !token.isEmpty {
                    onChunk(token)
                }
                if chunk.done == true { break }
            }
        }
    }

    // MARK: 私有

    private func makePayload(model: String,
                             messages: [ChatMessage],
                             systemPrompt: String,
                             stream: Bool) -> [String: Any] {
        var msgs: [[String: String]] = []
        if !systemPrompt.isEmpty {
            msgs.append(["role": ChatRole.system.rawValue, "content": systemPrompt])
        }
        for m in messages where m.role != .system {
            msgs.append(["role": m.role.rawValue, "content": m.content])
        }
        return [
            "model": model,
            "messages": msgs,
            "stream": stream
        ]
    }

    private static func ensureOK(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        if !(200..<300).contains(http.statusCode) {
            throw OllamaError.http(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
    }
}

// MARK: - 3. 持久化

/// 历史记录的本地存储。抽出来便于将来换数据库。
struct ChatHistoryStore: Sendable {
    let key: String

    init(key: String = "chatHistories.v2") { self.key = key }

    func load() -> [ChatSession] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ChatSession].self, from: data)) ?? []
    }

    func save(_ sessions: [ChatSession]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(sessions) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - 4. 业务逻辑 / ViewModel

@MainActor
final class OllamaManager: ObservableObject {

    // MARK: 配置（持久化）
    @AppStorage("serverURL")      var serverURL: String = ""
    @AppStorage("selectedModel")  var selectedModel: String = ""
    @AppStorage("systemPrompt")   var systemPrompt: String = "你是一个简洁、乐于助人的助手。回答尽量简短，便于在手表上阅读。"
    @AppStorage("autoScroll")     var autoScroll: Bool = true
    @AppStorage("showTimestamps") var showTimestamps: Bool = true

    // MARK: 状态
    @Published private(set) var availableModels: [OllamaTagsResponse.ModelTag] = []
    @Published private(set) var chatHistories: [ChatSession] = []
    @Published private(set) var currentSessionID: UUID?
    @Published private(set) var isGenerating: Bool = false
    @Published var errorMessage: String?       // 全局 toast
    @Published var statusMessage: String?      // 成功状态（短时显示）

    var currentSession: ChatSession? {
        guard let id = currentSessionID else { return nil }
        return chatHistories.first(where: { $0.id == id })
    }

    // MARK: 私有
    private let store = ChatHistoryStore()
    private var currentTask: Task<Void, Never>?

    // MARK: 生命周期
    init() {
        // 首次启动给一个合理的默认 IP 提示（用户必须改成自己局域网里的 Ollama 地址）
        if serverURL.isEmpty {
            serverURL = "http://192.168.1.100:11434"
        }
        // 自动化 launch arg：`-serverURL <url>` 覆盖配置（仅用于自动化截图）
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-serverURL"),
           i + 1 < ProcessInfo.processInfo.arguments.count {
            serverURL = ProcessInfo.processInfo.arguments[i + 1]
        }
        chatHistories = store.load()
        // selectedModel 兜底：fetchModels() 失败时仍能保留上次选择；若该模型已不在 availableModels 里，UI 会 fallback 到第一个
    }

    // MARK: URL 与 client

    /// 把用户输入的 serverURL 标准化为 URL
    var baseURL: URL? {
        let s = serverURL.trimmedForURL
        guard !s.isEmpty, let u = URL(string: s) else { return nil }
        return u
    }

    private func makeClient() throws -> OllamaClient {
        guard let base = baseURL else { throw OllamaError.invalidURL }
        return OllamaClient(baseURL: base)
    }

    // MARK: 模型

    /// 拉取模型并按选中持久化做兜底
    func fetchModels() async {
        log.info("fetchModels() called, serverURL=\(self.serverURL, privacy: .public)")
        do {
            let client = try makeClient()
            log.info("fetchModels() client created, calling /api/tags")
            let models = try await client.fetchModels()
            log.info("fetchModels() got \(models.count) models")
            availableModels = models
            // 兜底：之前选中的 model 不在列表里就选第一个；列表为空就清空
            if !models.contains(where: { $0.name == selectedModel }) {
                selectedModel = models.first?.name ?? ""
            }
            showStatus("✅ 已获取 \(models.count) 个模型")
        } catch {
            log.error("fetchModels() failed: \(String(describing: error), privacy: .public)")
            showError(error)
        }
    }

    /// 简单 ping，验证地址可达
    func testConnection() async {
        do {
            let client = try makeClient()
            try await client.health()
            showStatus("✅ 服务器可达")
        } catch {
            showError(error)
        }
    }

    // MARK: 会话管理

    func startNewSession() {
        currentSessionID = nil
    }

    func loadSession(_ s: ChatSession) {
        currentSessionID = s.id
    }

    func renameSession(_ s: ChatSession, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateSession(s.id) { session in
            session.title = String(trimmed.prefix(40))
            session.updatedAt = Date()
        }
    }

    func deleteSession(_ s: ChatSession) {
        chatHistories.removeAll { $0.id == s.id }
        if currentSessionID == s.id { currentSessionID = nil }
        persist()
    }

    func deleteSession(at offsets: IndexSet) {
        let toDelete = offsets.map { chatHistories[$0].id }
        chatHistories.remove(atOffsets: offsets)
        if let id = currentSessionID, toDelete.contains(id) { currentSessionID = nil }
        persist()
    }

    func clearAllHistory() {
        chatHistories.removeAll()
        currentSessionID = nil
        persist()
    }

    func deleteMessage(_ message: ChatMessage, in sessionID: UUID) {
        updateSession(sessionID) { $0.messages.removeAll { $0.id == message.id } }
    }

    /// 重试最后一对 user/assistant：删除最后的 assistant，并把最后的 user 重发一次。
    func retryLast() async {
        guard let s = currentSession, !s.messages.isEmpty else { return }
        // 删除末尾所有 assistant 消息，再触发 sendMessage 重新生成
        let last = s.messages.last!
        if last.role == .assistant {
            updateSession(s.id) { $0.messages.removeAll { $0.id == last.id } }
        }
        if let lastUser = currentSession?.messages.last, lastUser.role == .user {
            await streamGenerate(prompt: lastUser.content)
        } else {
            showStatus("没有可重试的用户消息")
        }
    }

    // MARK: 消息发送

    /// 发送 / 重发都会进入这个流式方法
    func sendMessage(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !selectedModel.isEmpty else {
            showError(NSError(domain: "ollama", code: 0,
                              userInfo: [NSLocalizedDescriptionKey: "请先在设置中选择模型"]))
            return
        }
        await streamGenerate(prompt: trimmed)
    }

    /// 内部：建立/复用 session，插入 user 消息，调用流式接口，逐 token 追加 assistant 消息
    private func streamGenerate(prompt: String) async {
        cancelCurrentTask()

        // 1. 确保有 session
        if currentSessionID == nil {
            let title = prompt.count > 10 ? String(prompt.prefix(10)) + "…" : prompt
            let new = ChatSession(title: title, systemPrompt: systemPrompt)
            chatHistories.insert(new, at: 0)
            currentSessionID = new.id
        }
        guard let sid = currentSessionID else { return }

        // 2. 插入 user 消息
        let userMsg = ChatMessage(role: .user, content: prompt)
        updateSession(sid) { $0.messages.append(userMsg) }
        // 自动 title：第一次用户消息时使用其前 10 字
        if let s = currentSession, s.messages.count == 1 {
            updateSession(sid) { $0.title = String(prompt.prefix(10)) + (prompt.count > 10 ? "…" : "") }
        }

        // 3. 准备一个空的 assistant 消息用于流式追加
        let assistantMsg = ChatMessage(role: .assistant, content: "", isStreaming: true)
        updateSession(sid) { $0.messages.append(assistantMsg) }
        let assistantID = assistantMsg.id

        isGenerating = true
        defer { isGenerating = false }

        // 4. 启动流式任务
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let client = try self.makeClient()
                // 把历史（包含刚追加的 user）发出去；过滤掉占位的空 assistant 消息
                let history = self.currentSession?.messages.filter { !$0.isStreaming && $0.id != assistantID } ?? []
                try await client.streamChat(
                    model: self.selectedModel,
                    messages: history,
                    systemPrompt: self.systemPrompt
                ) { [weak self] token in
                    guard let self else { return }
                    self.appendStreamingToken(token, to: assistantID, in: sid)
                }
                // 收尾：清掉流式标记
                self.finalizeStreamingMessage(assistantID, in: sid)
            } catch is CancellationError {
                self.finalizeStreamingMessage(assistantID, in: sid, cancelled: true)
            } catch let e as URLError where e.code == .cancelled {
                self.finalizeStreamingMessage(assistantID, in: sid, cancelled: true)
            } catch OllamaError.cancelled {
                self.finalizeStreamingMessage(assistantID, in: sid, cancelled: true)
            } catch {
                // 流式失败时回滚空 assistant 消息
                self.updateSession(sid) { $0.messages.removeAll { $0.id == assistantID } }
                self.showError(error)
            }
        }
        await currentTask?.value
    }

    func cancelCurrentTask() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: 消息更新工具

    private func updateSession(_ id: UUID, _ mutate: (inout ChatSession) -> Void) {
        guard let idx = chatHistories.firstIndex(where: { $0.id == id }) else { return }
        mutate(&chatHistories[idx])
        chatHistories[idx].updatedAt = Date()
        persist()
    }

    private func appendStreamingToken(_ token: String, to messageID: UUID, in sessionID: UUID) {
        guard let sidx = chatHistories.firstIndex(where: { $0.id == sessionID }),
              let midx = chatHistories[sidx].messages.firstIndex(where: { $0.id == messageID })
        else { return }
        chatHistories[sidx].messages[midx].content += token
        chatHistories[sidx].updatedAt = Date()
        // 流式过程中频繁写盘会很慢，所以这里只写内存；等 finalize 时统一持久化
    }

    private func finalizeStreamingMessage(_ id: UUID, in sessionID: UUID, cancelled: Bool = false) {
        updateSession(sessionID) { session in
            guard let idx = session.messages.firstIndex(where: { $0.id == id }) else { return }
            session.messages[idx].isStreaming = false
            if cancelled {
                session.messages[idx].content += "\n\n（已停止生成）"
            }
        }
    }

    private func persist() {
        store.save(chatHistories)
    }

    // MARK: 提示

    func showError(_ error: Error) {
        let desc: String
        if let e = error as? LocalizedError, let d = e.errorDescription {
            desc = d
        } else {
            desc = error.localizedDescription
        }
        errorMessage = desc
        log.error("❌ \(desc, privacy: .public)")
    }

    func showStatus(_ msg: String) {
        statusMessage = msg
        log.info("✅ \(msg, privacy: .public)")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self?.statusMessage == msg { self?.statusMessage = nil }
        }
    }

    // MARK: 剪贴板 / 共享

    /// watchOS 没有 UIPasteboard。给一段文字生成可分享的字符串。
    /// UI 层用 `ShareLink(item:)` 让用户通过 AirDrop / Messages / Mail 等系统通道分享，相当于跨设备"复制"。
    func shareableText(for message: ChatMessage) -> String {
        "[\(message.role.rawValue)] \(message.content)"
    }
}

// MARK: - 5. 视图

// 5.1 根 TabView
struct ContentView: View {
    @StateObject private var manager = OllamaManager()
    @State private var selectedTab: Int = ContentView.initialTabFromLaunchArgs()

    /// 用 launch arg `-tab N` 决定初始 Tab（仅用于自动化截图，运行时无副作用）
    private static func initialTabFromLaunchArgs() -> Int {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-tab"), i + 1 < args.count,
              let n = Int(args[i + 1]) else { return 0 }
        return max(0, min(2, n))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ChatView(manager: manager)
                .tag(0)
                .tabItem { Image(systemName: "message.fill"); Text("对话") }

            HistoryView(manager: manager)
                .tag(1)
                .tabItem { Image(systemName: "clock.fill"); Text("历史") }

            SettingsView(manager: manager)
                .tag(2)
                .tabItem { Image(systemName: "gearshape.fill"); Text("设置") }
        }
        .overlay(alignment: .top) {
            ToastBanner(status: manager.statusMessage, error: manager.errorMessage)
                .padding(.top, 2)
        }
        .task {
            // 仅用于自动化截图：传 `-autoTest` 时启动后自动尝试一次连接，便于截到错误 toast
            if ProcessInfo.processInfo.arguments.contains("-autoTest") {
                await manager.fetchModels()
            }
        }
    }
}

// 5.2 顶部 Toast
struct ToastBanner: View {
    let status: String?
    let error: String?
    var body: some View {
        VStack(spacing: 2) {
            if let s = status {
                Text(s)
                    .font(.caption2)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.green.opacity(0.85), in: Capsule())
                    .foregroundColor(.white)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let e = error {
                Text(e)
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.red.opacity(0.85), in: Capsule())
                    .foregroundColor(.white)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: status)
        .animation(.easeInOut(duration: 0.25), value: error)
    }
}

// 5.3 对话页
struct ChatView: View {
    @ObservedObject var manager: OllamaManager
    @State private var inputText: String = ""
    @FocusState private var inputFocused: Bool
    @State private var showRenameAlert = false
    @State private var renameText: String = ""
    @State private var showActions = false   // 顶部操作（替代 watchOS 不可用的 Menu）

    private static let quickPrompts: [String] = [
        "用一句话解释量子纠缠",
        "给我一个 7 天减脂建议",
        "把『生日快乐』翻译成法语",
        "讲个 50 字的冷笑话"
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 6) {
                messagesList
                inputBar
            }
            .navigationTitle(currentTitle)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showActions = true
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .confirmationDialog("操作", isPresented: $showActions, titleVisibility: .hidden) {
                        Button("新建对话") { manager.startNewSession() }
                        if manager.currentSession != nil {
                            Button("重命名") {
                                renameText = manager.currentSession?.title ?? ""
                                showRenameAlert = true
                            }
                        }
                        Button("重试上一条") {
                            Task { await manager.retryLast() }
                        }
                        .disabled(manager.currentSession == nil || manager.isGenerating)
                        Button("取消", role: .cancel) {}
                    }
                }
            }
        }
        .alert("重命名对话", isPresented: $showRenameAlert) {
            TextField("标题", text: $renameText)
            Button("保存") {
                if let s = manager.currentSession {
                    manager.renameSession(s, to: renameText)
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var currentTitle: String {
        manager.currentSession?.title ?? "新对话"
    }

    @ViewBuilder
    private var messagesList: some View {
        if let session = manager.currentSession, !session.messages.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(session.messages) { msg in
                            MessageRow(message: msg,
                                       showTimestamp: manager.showTimestamps,
                                       onDelete: { manager.deleteMessage(msg, in: session.id) })
                                .id(msg.id)
                        }
                        if manager.isGenerating {
                            TypingIndicator().id("typing")
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: session.messages.count) { _, _ in
                    guard manager.autoScroll else { return }
                    scrollToBottom(proxy)
                }
                .onChange(of: manager.isGenerating) { _, gen in
                    if gen { scrollToBottom(proxy, anchor: "typing") }
                }
            }
        } else {
            emptyState
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, anchor: AnyHashable? = nil) {
        if let a = anchor {
            withAnimation { proxy.scrollTo(a, anchor: .bottom) }
        } else if let last = manager.currentSession?.messages.last {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 8)
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("和你的专属 AI 聊聊吧")
                .font(.footnote)
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Self.quickPrompts, id: \.self) { q in
                    Button {
                        inputText = q
                    } label: {
                        Text("· \(q)")
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var inputBar: some View {
        HStack(spacing: 6) {
            TextField("说点什么…", text: $inputText)
                .focused($inputFocused)
                .onSubmit { send() }

            if manager.isGenerating {
                Button {
                    manager.cancelCurrentTask()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .foregroundColor(.red)
                }
                .frame(width: 32)
            } else {
                Button {
                    send()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .foregroundColor(inputText.trimmingCharacters(in: .whitespaces).isEmpty ? .gray : .blue)
                }
                .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty)
                .frame(width: 32)
            }
        }
        .padding(.horizontal, 4)
    }

    private func send() {
        let text = inputText
        inputText = ""
        Task { await manager.sendMessage(text) }
    }
}

// 5.4 单条消息
struct MessageRow: View {
    let message: ChatMessage
    let showTimestamp: Bool
    let onDelete: () -> Void

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .bottom) {
            if isUser { Spacer(minLength: 24) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
                bubble
                    .swipeActions(edge: .leading) {
                        // 分享（替代 watchOS 上不可用的复制 / 上下文菜单）
                        ShareLink(item: message.content,
                                  preview: SharePreview(message.content.prefix(40) + (message.content.count > 40 ? "…" : ""))) {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                        .tint(.blue)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive, action: onDelete) {
                            Label("删除", systemImage: "trash")
                        }
                    }
                if showTimestamp {
                    Text(Self.formatter.string(from: message.timestamp))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)

            if !isUser { Spacer(minLength: 24) }
        }
    }

    @ViewBuilder
    private var bubble: some View {
        Group {
            if isUser {
                Text(message.content)
            } else {
                // Markdown 渲染：先用 inlineOnly 解析，失败则降级到纯文本。
                if let attr = try? AttributedString(
                    markdown: message.content,
                    options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                ) {
                    Text(attr)
                } else {
                    Text(message.content)
                }
            }
        }
        .font(.footnote)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isUser ? Color.blue.opacity(0.85) : Color.gray.opacity(0.25),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .foregroundColor(isUser ? .white : .primary)
        .overlay(alignment: .bottomTrailing) {
            if message.isStreaming {
                BlinkingCursor()
                    .offset(x: 4, y: -2)
            }
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}

// 5.5 打字光标
struct BlinkingCursor: View {
    @State private var on = true
    var body: some View {
        Rectangle()
            .fill(Color.primary)
            .frame(width: 6, height: 10)
            .opacity(on ? 1 : 0)
            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: on)
            .onAppear { on.toggle() }
    }
}

// 5.6 typing indicator
struct TypingIndicator: View {
    @State private var phase: Int = 0
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 5, height: 5)
                    .opacity(phase == i ? 1 : 0.25)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.gray.opacity(0.2), in: Capsule())
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 350_000_000)
                phase = (phase + 1) % 3
            }
        }
    }
}

// 5.7 历史页
struct HistoryView: View {
    @ObservedObject var manager: OllamaManager
    @State private var renamingSession: ChatSession?
    @State private var renameText: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        manager.startNewSession()
                    } label: {
                        Label("新建对话", systemImage: "plus.circle.fill")
                    }
                }

                if manager.chatHistories.isEmpty {
                    Text("还没有历史对话")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    Section("历史") {
                        ForEach(manager.chatHistories) { s in
                            HistoryRow(session: s)
                                .contentShape(Rectangle())
                                .onTapGesture { manager.loadSession(s) }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        manager.deleteSession(s)
                                    } label: { Label("删除", systemImage: "trash") }

                                    Button {
                                        beginRename(s)
                                    } label: { Label("重命名", systemImage: "pencil") }
                                    .tint(.blue)
                                }
                        }
                        .onDelete(perform: manager.deleteSession)
                    }
                }
            }
            .navigationTitle("历史")
            .alert("重命名对话", isPresented: Binding(
                get: { renamingSession != nil },
                set: { if !$0 { renamingSession = nil } })) {
                TextField("标题", text: $renameText)
                Button("保存") {
                    if let s = renamingSession { manager.renameSession(s, to: renameText) }
                    renamingSession = nil
                }
                Button("取消", role: .cancel) { renamingSession = nil }
            }
        }
    }

    private func beginRename(_ s: ChatSession) {
        renameText = s.title
        renamingSession = s
    }
}

struct HistoryRow: View {
    let session: ChatSession

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.title)
                .font(.footnote)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text("\(session.messages.count) 条")
                Text("·")
                Text(Self.df.string(from: session.updatedAt))
            }
            .font(.system(size: 9))
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// 5.8 设置页
struct SettingsView: View {
    @ObservedObject var manager: OllamaManager
    @State private var showClearConfirm = false
    @State private var showSystemEditor = false
    @State private var draftSystemPrompt: String = ""

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                modelSection
                behaviorSection
                dataSection
            }
            .navigationTitle("设置")
            .onAppear { draftSystemPrompt = manager.systemPrompt }
        }
    }

    @ViewBuilder
    private var serverSection: some View {
        Section("服务器") {
            TextField("http://IP:11434", text: $manager.serverURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button {
                Task { await manager.testConnection() }
            } label: {
                Label("测试连接", systemImage: "stethoscope")
            }

            Button {
                Task { await manager.fetchModels() }
            } label: {
                Label("获取模型列表", systemImage: "arrow.triangle.2.circlepath")
            }
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        Section("模型") {
            if manager.availableModels.isEmpty {
                Text("请先连接服务器获取模型")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Picker("当前模型", selection: $manager.selectedModel) {
                    ForEach(manager.availableModels, id: \.name) { m in
                        Text(m.name).tag(m.name)
                    }
                }
            }

            if let current = manager.availableModels.first(where: { $0.name == manager.selectedModel }) {
                LabeledContent("大小", value: Self.formatBytes(current.size))
                if let modified = current.modified_at {
                    LabeledContent("更新", value: Self.dateFmt.string(from: modified))
                }
            }
        }
    }

    @ViewBuilder
    private var behaviorSection: some View {
        Section("行为") {
            Toggle("自动滚动到最新", isOn: $manager.autoScroll)
            Toggle("显示消息时间", isOn: $manager.showTimestamps)

            Button {
                draftSystemPrompt = manager.systemPrompt
                showSystemEditor = true
            } label: {
                Label("系统提示词…", systemImage: "text.bubble")
            }
            .sheet(isPresented: $showSystemEditor) {
                NavigationStack {
                    Form {
                        Section {
                            // watchOS 上没有 TextEditor，用 axis: .vertical 的 TextField 多行输入
                            TextField("系统提示词", text: $draftSystemPrompt, axis: .vertical)
                                .lineLimit(3...8)
                        } header: {
                            Text("系统提示词（每次对话开始前注入）")
                        } footer: {
                            Text("建议尽量短，手表屏幕下过长的 prompt 会拖慢首字延迟")
                        }
                    }
                    .navigationTitle("系统提示词")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("保存") {
                                manager.systemPrompt = draftSystemPrompt
                                showSystemEditor = false
                            }
                        }
                        ToolbarItem(placement: .topBarLeading) {
                            Button("取消") { showSystemEditor = false }
                        }
                    }
                }
            }

            if let s = manager.currentSession {
                LabeledContent("当前对话", value: s.title)
            }
        }
    }

    @ViewBuilder
    private var dataSection: some View {
        Section("数据") {
            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label("清空全部历史", systemImage: "trash")
            }
            .alert("清空全部历史？", isPresented: $showClearConfirm) {
                Button("清空", role: .destructive) { manager.clearAllHistory() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("此操作不可撤销。")
            }
        }
    }

    private static func formatBytes(_ b: Int64?) -> String {
        guard let b, b > 0 else { return "—" }
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB]
        f.countStyle = .file
        return f.string(fromByteCount: b)
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}

// MARK: - 6. App 入口
@main
struct OllamaWatchApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

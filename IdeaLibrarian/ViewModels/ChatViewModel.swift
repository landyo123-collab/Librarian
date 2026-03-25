import SwiftUI
import Combine
import Foundation
import UniformTypeIdentifiers
#if canImport(IdeaLibrarianCore)
import IdeaLibrarianCore
#endif

@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var queryInput: String = ""
    @Published var isProcessing: Bool = false
    @Published var currentContext: RetrievalContext?
    @Published var showContext: Bool = true
    @Published var showIndexSheet: Bool = false
    @Published var showStatsSheet: Bool = false
    @Published var showCorpusSheet: Bool = false
    @Published var isIndexing: Bool = false
    @Published var indexProgress: IndexProgress?
    @Published var stats: DatabaseStatistics?
    @Published var conversations: [Conversation] = []
    @Published var selectedConversationId: String?

    // Corpus browser state (paged; never loads all chunks at once)
    @Published var corpusFilter: CorpusChunkFilter = .all
    @Published var corpusPageSize: Int = 2000
    @Published var corpusPageIndex: Int = 0
    @Published var corpusTotalCount: Int = 0
    @Published var corpusRows: [ChunkCorpusRow] = []
    @Published var isCorpusLoading: Bool = false
    @Published var isImportDropTargeted: Bool = false
    @Published var isImportingFolders: Bool = false
    @Published var importStatusMessage: String?
    @Published var importStatusIsError: Bool = false

    private let engine: AtlasEngine
    let userLibraryPath: String
    private let userLibraryURL: URL
    nonisolated private static let responseArchiveURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return appSupport
            .appendingPathComponent("Librarian", isDirectory: true)
            .appendingPathComponent("Answers", isDirectory: true)
    }()
    private var corpusRefreshTask: Task<Void, Never>?
    private var pendingImportReindex: Bool = false

    var importDestinationPath: String {
        userLibraryURL.path
    }

    init(engine: AtlasEngine, userLibraryPath: String) {
        self.engine = engine
        let normalizedRoot = URL(fileURLWithPath: userLibraryPath).standardizedFileURL
        self.userLibraryURL = normalizedRoot
        self.userLibraryPath = normalizedRoot.path
        do {
            try FileManager.default.createDirectory(at: self.userLibraryURL, withIntermediateDirectories: true)
        } catch {
            self.importStatusMessage = "Import setup warning: \(error.localizedDescription)"
            self.importStatusIsError = true
        }
        self.loadConversations()
        self.refreshStats()
    }

    // MARK: - Query

    func submitQuery() async {
        guard !queryInput.isEmpty else { return }

        let query = queryInput
        queryInput = ""
        isProcessing = true

        let conversationId = ensureConversationSelected(defaultTitle: query)

        // Add + persist user message
        let userMessage = ChatMessage(
            conversationId: conversationId,
            role: .user,
            content: query
        )
        messages.append(userMessage)
        try? engine.saveMessage(userMessage)
        try? engine.touchConversation(id: conversationId)

        // If this is the first message in a new chat, set title from it.
        if messages.count == 1 {
            let title = Self.truncateTitle(query)
            try? engine.updateConversationTitle(id: conversationId, title: title)
            self.loadConversations()
        } else {
            self.loadConversations()
        }

        do {
            engine.setActiveConversation(conversationId)
            let result = try await engine.processQueryConversational(query, conversationId: conversationId)

            currentContext = result.context
            showContext = true

            let responseContent = result.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "I wasn't able to generate a response — the query may have been too complex for the current token budget. Try rephrasing or breaking it into smaller questions."
                : result.response

            let assistantMessage = ChatMessage(
                conversationId: conversationId,
                role: .assistant,
                content: responseContent,
                sourceChunks: result.context.results.map { $0.chunk.id },
                ccrScore: result.ccrScore
            )
            messages.append(assistantMessage)
            try? engine.saveMessage(assistantMessage)
            try? engine.touchConversation(id: conversationId)
            self.loadConversations()
            Task.detached(priority: .utility) {
                Self.archiveAssistantResponse(assistantMessage.content)
            }

        } catch {
            let errorMessage = ChatMessage(
                conversationId: conversationId,
                role: .assistant,
                content: "Error: \(error.localizedDescription)"
            )
            messages.append(errorMessage)
            try? engine.saveMessage(errorMessage)
            try? engine.touchConversation(id: conversationId)
            self.loadConversations()
            Task.detached(priority: .utility) {
                Self.archiveAssistantResponse(errorMessage.content)
            }
        }

        isProcessing = false
    }

    // MARK: - Conversation

    func newConversation() {
        let conversation = try? engine.createConversation(title: "New chat")
        selectedConversationId = conversation?.id
        engine.setActiveConversation(conversation?.id)
        messages = []
        currentContext = nil
        loadConversations()
    }

    func selectConversation(id: String?) {
        // If a query is in flight, don't reload messages from DB —
        // the in-memory messages array is authoritative during processing.
        guard !isProcessing else {
            selectedConversationId = id
            engine.setActiveConversation(id)
            return
        }

        selectedConversationId = id
        engine.setActiveConversation(id)
        currentContext = nil

        guard let id else {
            messages = []
            return
        }

        messages = (try? engine.getMessages(conversationId: id, limit: 200)) ?? []
    }

    private func loadConversations() {
        conversations = (try? engine.getConversations()) ?? []

        if selectedConversationId == nil {
            if let first = conversations.first {
                selectedConversationId = first.id
                engine.setActiveConversation(first.id)
                messages = (try? engine.getMessages(conversationId: first.id, limit: 200)) ?? []
            } else {
                newConversation()
            }
        }
    }

    private func ensureConversationSelected(defaultTitle: String) -> String {
        if let selectedConversationId {
            return selectedConversationId
        }

        if let first = conversations.first {
            selectedConversationId = first.id
            engine.setActiveConversation(first.id)
            return first.id
        }

        let conv = (try? engine.createConversation(title: Self.truncateTitle(defaultTitle)))
            ?? (try? engine.createConversation(title: "New chat"))

        selectedConversationId = conv?.id
        engine.setActiveConversation(conv?.id)
        loadConversations()

        if let selectedConversationId {
            return selectedConversationId
        }

        // Should be unreachable; keep UI functional even if DB is unavailable.
        return UUID().uuidString
    }

    private static func truncateTitle(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "New chat" }
        if trimmed.count <= 60 { return trimmed }
        return String(trimmed.prefix(60)) + "..."
    }

    // MARK: - Indexing

    func startIndexing() async {
        await runIndexing(triggeredByImport: false)
    }

    private func runIndexing(triggeredByImport: Bool) async {
        if isIndexing {
            if triggeredByImport {
                pendingImportReindex = true
                importStatusMessage = "Import complete. Indexing is currently running; queued a follow-up indexing pass."
                importStatusIsError = false
            }
            return
        }

        isIndexing = true
        do {
            try await engine.indexKnowledgeBase { progress in
                Task { @MainActor in
                    self.indexProgress = progress
                }
            }
            if triggeredByImport {
                importStatusMessage = "Import indexing complete."
                importStatusIsError = false
            }
        } catch {
            if triggeredByImport {
                importStatusMessage = "Import indexing failed: \(error.localizedDescription)"
                importStatusIsError = true
            } else {
                print("Indexing error: \(error)")
            }
        }

        isIndexing = false
        refreshStats()

        if pendingImportReindex {
            pendingImportReindex = false
            importStatusMessage = "Running queued indexing pass for recent imports..."
            importStatusIsError = false
            await runIndexing(triggeredByImport: true)
        }
    }

    func startEmbeddings() async {
        if isIndexing {
            importStatusMessage = "Busy indexing. Wait for indexing to finish before generating embeddings."
            importStatusIsError = true
            return
        }
        isIndexing = true
        do {
            try await engine.generateEmbeddings { progress in
                Task { @MainActor in
                    self.indexProgress = progress
                    if !progress.isIndexing {
                        self.isIndexing = false
                    }
                }
            }
        } catch {
            isIndexing = false
            print("Embedding error: \(error)")
        }
    }

    // MARK: - Folder Import (Drag & Drop)

    func importDroppedFolders(from providers: [NSItemProvider]) async {
        guard !isImportingFolders else {
            importStatusMessage = "Import already in progress."
            importStatusIsError = true
            return
        }

        isImportingFolders = true
        defer { isImportingFolders = false }

        let sourceURLs = await Self.extractFileURLs(from: providers)
        guard !sourceURLs.isEmpty else {
            importStatusMessage = "Drop folders (not files) to import."
            importStatusIsError = true
            return
        }

        let sourcePaths = sourceURLs.map { $0.standardizedFileURL.path }
        let destinationPath = self.importDestinationPath

        let result = await Task.detached(priority: .userInitiated) {
            Self.performFolderImport(
                sourcePaths: sourcePaths,
                destinationPath: destinationPath
            )
        }.value

        if !result.importedNames.isEmpty {
            let importedLabel = result.importedNames.joined(separator: ", ")
            if result.failureMessages.isEmpty {
                importStatusMessage = "Imported: \(importedLabel). Starting indexing..."
                importStatusIsError = false
            } else {
                importStatusMessage = "Imported: \(importedLabel). Some items failed: \(result.failureMessages.joined(separator: " | "))"
                importStatusIsError = true
            }
            await runIndexing(triggeredByImport: true)
            return
        }

        importStatusMessage = result.failureMessages.isEmpty
            ? "No folders were imported."
            : "Import failed: \(result.failureMessages.joined(separator: " | "))"
        importStatusIsError = true
    }

    // MARK: - Stats

    func refreshStats() {
        stats = try? engine.getStatistics()
    }

    // MARK: - Corpus Browser

    func startCorpusBrowsing() {
        Task { await reloadCorpus() }
        startCorpusAutoRefresh()
    }

    func stopCorpusBrowsing() {
        corpusRefreshTask?.cancel()
        corpusRefreshTask = nil
    }

    func reloadCorpus() async {
        await loadCorpusPage(index: corpusPageIndex)
    }

    var corpusPageCount: Int {
        guard corpusPageSize > 0 else { return 0 }
        if corpusTotalCount == 0 { return 0 }
        return Int(ceil(Double(corpusTotalCount) / Double(corpusPageSize)))
    }

    var corpusRangeLabel: String {
        let total = corpusTotalCount
        guard total > 0 else { return "0-0/0" }
        let start0 = max(0, corpusPageIndex) * max(1, corpusPageSize)
        let start1 = min(total, start0 + 1) // 1-based
        let end1 = min(total, start0 + corpusRows.count)
        return "\(start1)-\(end1)/\(total)"
    }

    func goToFirstCorpusPage() {
        corpusPageIndex = 0
        Task { await reloadCorpus() }
    }

    func goToPrevCorpusPage() {
        corpusPageIndex = max(0, corpusPageIndex - 1)
        Task { await reloadCorpus() }
    }

    func goToNextCorpusPage() {
        let last = max(0, corpusPageCount - 1)
        corpusPageIndex = min(last, corpusPageIndex + 1)
        Task { await reloadCorpus() }
    }

    func goToLastCorpusPage() {
        corpusPageIndex = max(0, corpusPageCount - 1)
        Task { await reloadCorpus() }
    }

    func setCorpusFilter(_ filter: CorpusChunkFilter) {
        corpusFilter = filter
        corpusPageIndex = 0
        Task { await reloadCorpus() }
    }

    func setCorpusPageSize(_ size: Int) {
        corpusPageSize = size
        corpusPageIndex = 0
        Task { await reloadCorpus() }
    }

    private func startCorpusAutoRefresh() {
        corpusRefreshTask?.cancel()
        corpusRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await self.refreshCorpusSnapshotIfReasonable()
            }
        }
    }

    private func refreshCorpusSnapshotIfReasonable() async {
        guard showCorpusSheet else { return }
        let filter = corpusFilter
        let total = (try? engine.getCorpusCount(filter: filter)) ?? 0
        self.corpusTotalCount = total

        // Clamp page index if corpus grew/shrank.
        let last = max(0, corpusPageCount - 1)
        if corpusPageIndex > last {
            corpusPageIndex = last
        }

        // Refresh the currently visible page (2,000 rows by default).
        await loadCorpusPage(index: corpusPageIndex)
    }

    private func loadCorpusPage(index: Int) async {
        if isCorpusLoading { return }
        isCorpusLoading = true

        let filter = corpusFilter
        let limit = max(50, corpusPageSize)
        let offset = max(0, index) * limit

        do {
            let total = try engine.getCorpusCount(filter: filter)
            let page = try engine.getCorpusPage(filter: filter, limit: limit, offset: offset)
            self.corpusTotalCount = total
            self.corpusRows = page
        } catch {
            // Best-effort; keep UI usable.
        }
        self.isCorpusLoading = false
    }

    private struct FolderImportOutcome {
        let importedNames: [String]
        let failureMessages: [String]
    }

    nonisolated private static func extractFileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let url = await loadFileURL(from: provider) {
                urls.append(url)
            }
        }
        return urls
    }

    nonisolated private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                    return
                }

                if let data = item as? Data,
                   let string = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   let url = URL(string: string) {
                    continuation.resume(returning: url)
                    return
                }

                if let string = item as? String,
                   let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    continuation.resume(returning: url)
                    return
                }

                continuation.resume(returning: nil)
            }
        }
    }

    nonisolated private static func performFolderImport(
        sourcePaths: [String],
        destinationPath: String
    ) -> FolderImportOutcome {
        let fileManager = FileManager.default
        let userLibraryURL = URL(fileURLWithPath: destinationPath).standardizedFileURL
        var importedNames: [String] = []
        var failureMessages: [String] = []

        do {
            try fileManager.createDirectory(at: userLibraryURL, withIntermediateDirectories: true)
        } catch {
            return FolderImportOutcome(
                importedNames: [],
                failureMessages: ["Could not create UserLibrary at \(userLibraryURL.path): \(error.localizedDescription)"]
            )
        }

        for rawPath in sourcePaths {
            let sourceURL = URL(fileURLWithPath: rawPath).standardizedFileURL
            let sourcePath = sourceURL.path

            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: sourcePath, isDirectory: &isDir), isDir.boolValue else {
                failureMessages.append("Skipped non-folder item: \(sourceURL.lastPathComponent)")
                continue
            }

            if sourceURL == userLibraryURL {
                failureMessages.append("Skipped UserLibrary folder itself: \(sourceURL.lastPathComponent)")
                continue
            }

            if sourcePath == userLibraryURL.path || sourcePath.hasPrefix(userLibraryURL.path + "/") {
                failureMessages.append("Skipped folder already inside UserLibrary: \(sourceURL.lastPathComponent)")
                continue
            }

            let requestedName = sanitizedFolderName(sourceURL.lastPathComponent)
            let destinationURL = uniqueImportDestination(
                requestedName: requestedName,
                in: userLibraryURL,
                fileManager: fileManager
            )

            let hasSecurityScope = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                importedNames.append(destinationURL.lastPathComponent)
            } catch {
                failureMessages.append("Failed to import \(sourceURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return FolderImportOutcome(importedNames: importedNames, failureMessages: failureMessages)
    }

    nonisolated private static func sanitizedFolderName(_ original: String) -> String {
        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "ImportedFolder" : trimmed
    }

    nonisolated private static func uniqueImportDestination(
        requestedName: String,
        in destinationURL: URL,
        fileManager: FileManager
    ) -> URL {
        var candidate = destinationURL.appendingPathComponent(requestedName, isDirectory: true)
        if !fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }

        var counter = 2
        while counter < 10_000 {
            candidate = destinationURL.appendingPathComponent("\(requestedName)-\(counter)", isDirectory: true)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }

        return destinationURL.appendingPathComponent("\(requestedName)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    nonisolated private static func archiveAssistantResponse(_ content: String) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: responseArchiveURL, withIntermediateDirectories: true)
        } catch {
            print("Archive directory error: \(error)")
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let timestamp = formatter.string(from: Date())
        let suffix = UUID().uuidString.prefix(8)
        let filename = "\(timestamp)_\(suffix).md"
        let fileURL = responseArchiveURL.appendingPathComponent(filename)

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            print("Archive write error: \(error)")
        }
    }
}

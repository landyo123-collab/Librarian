import Foundation

public class AtlasEngine {
    private let config: Configuration
    private let store: SQLiteStore
    private let indexManager: IndexManager
    private let hybridSearchEngine: HybridSearchEngine
    private let contextAssembler: ContextAssembler
    private let reasoner: Reasoner
    private let distillationEngine: DistillationEngine
    private let atlasNotePersister: AtlasNotePersister
    private let frameworkDetector: FrameworkDetector
    private let triggerRegistry: TriggerRegistry
    private let executionPlanner: ExecutionPlanner
    private let promptBuilder: PromptBuilder
    private let deepSeekClient: DeepSeekClient
    private let semanticRetriever: SemanticRetriever
    private let reasoningChain: ReasoningChain

    // Active conversation tracking
    private var activeConversationId: String?

    public init(config: Configuration) throws {
        self.config = config

        // Initialize database
        self.store = try SQLiteStore(path: config.databasePath)
        print("SQLite DB: \(config.databasePath)")

        // Initialize scanning and parsing
        let scanner = DocumentScanner()
        let chunkingStrategy = ChunkingStrategy(maxTokens: config.chunkSize)
        let parser = JSONEpisodeParser(chunkingStrategy: chunkingStrategy)

        // Initialize embedding provider
        let embeddingProvider = EmbeddingProvider(
            apiKey: config.openAIAPIKey,
            model: config.embeddingModel
        )

        // Initialize index manager
        self.indexManager = IndexManager(
            store: store,
            scanner: scanner,
            parser: parser,
            embeddingProvider: embeddingProvider,
            batchSize: config.batchSize
        )

        // Initialize retrieval components
        let lexicalRetriever = LexicalRetriever(store: store)
        let semanticRetriever = SemanticRetriever(store: store, embeddingProvider: embeddingProvider)
        self.semanticRetriever = semanticRetriever

        self.hybridSearchEngine = HybridSearchEngine(
            store: store,
            lexicalRetriever: lexicalRetriever,
            semanticRetriever: semanticRetriever,
            config: config
        )

        // Initialize context building
        let tokenBudgetManager = TokenBudgetManager()
        self.contextAssembler = ContextAssembler(tokenBudgetManager: tokenBudgetManager)

        // Initialize reasoning
        self.deepSeekClient = DeepSeekClient(apiKey: config.deepSeekAPIKey, model: config.deepSeekModel)
        self.promptBuilder = PromptBuilder()
        let citationValidator = CitationValidator()

        self.reasoner = Reasoner(
            deepSeekClient: deepSeekClient,
            promptBuilder: promptBuilder,
            citationValidator: citationValidator,
            contextAssembler: contextAssembler,
            config: config
        )

        // Initialize distillation
        self.distillationEngine = DistillationEngine(notePriorityBoost: config.notePriorityBoost)
        self.atlasNotePersister = AtlasNotePersister(store: store)

        // Initialize execution planner (central query authority)
        // Uses TriggerLexicon, QueryPolicy, TopicSynthesisDetector internally
        self.executionPlanner = ExecutionPlanner(config: config)

        let registry = FrameworkRegistry(entries: [])
        self.frameworkDetector = FrameworkDetector(registry: registry)
        self.triggerRegistry = TriggerRegistry.load(from: config.triggerLexiconPath)

        // Phase 11: GPT-5 mini synthesis layer
        let miniClient = OpenAIChatClient(
            apiKey: config.openAIAPIKey,
            model: config.gptMiniModel
        )
        self.reasoningChain = ReasoningChain(
            miniClient: miniClient,
            semanticRetriever: semanticRetriever,
            store: store,
            promptBuilder: self.promptBuilder,
            config: config
        )

#if DEBUG
        if ProcessInfo.processInfo.environment["IDEALIBRARIAN_DECOMPOSE_DEMO"] == "1" {
            QueryDecomposer.demo()
        }
#endif
    }

    // MARK: - Indexing

    public func indexKnowledgeBase(progressCallback: @escaping (IndexProgress) -> Void) async throws {
        let url = URL(fileURLWithPath: config.corpusPath)
        try await indexManager.indexDirectory(url, progressCallback: progressCallback)
    }

    public func generateEmbeddings(progressCallback: @escaping (IndexProgress) -> Void) async throws {
        try await indexManager.generateEmbeddings(progressCallback: progressCallback)
    }

    public func getStatistics() throws -> DatabaseStatistics {
        return try indexManager.getStatistics()
    }

    // MARK: - Corpus Browser

    public func getCorpusCount(filter: CorpusChunkFilter) throws -> Int {
        return try store.countCorpusChunks(filter: filter)
    }

    public func getCorpusPage(
        filter: CorpusChunkFilter,
        limit: Int,
        offset: Int
    ) throws -> [ChunkCorpusRow] {
        return try store.getCorpusChunks(filter: filter, limit: limit, offset: offset)
    }

    // MARK: - Query Processing

    public func processQuery(_ query: String) async throws -> QueryResult {
        let startTime = Date()

        let policy = config.defaultPolicy
        let detection = frameworkDetector.detect(query: query)
        let triggerIntensity = triggerRegistry.intensity(for: query)
        let triggerDrivenK = triggerRegistry.topK(for: triggerIntensity)
        var intent = classifyIntent(query)
        if !detection.matches.isEmpty && (intent == .general || intent == .smallTalk) {
            intent = .atlasRequested
        }

        // Effective citation and source visibility driven by config flags + intent
        let citeRequested: Bool = {
            if intent == .citeRequested { return true }
            if policy == .librarian { return config.showCitationsInLibrarian }
            return config.showCitationsInChat
        }()

        let showSources: Bool = {
            if intent == .citeRequested { return true }
            if policy == .librarian { return config.showSourcesInLibrarian }
            return config.showSourcesInChat
        }()

        let resolvedK = resolveTopK(policy: policy, intent: intent)
        let topK = max(resolvedK, triggerDrivenK)

        if !triggerIntensity.isZero {
            print("Trigger intensity: \(triggerIntensity) -> \(triggerDrivenK) retrieval")
        }
        var lexicalBoostRequested = false

        if policy == .chat && intent == .general && topK == 0 {
            if (try? hybridSearchEngine.hasLexicalMatches(query: query, limit: 5)) == true {
                lexicalBoostRequested = true
                print("Lexical hits detected for general query; enabling retrieval.")
            }
        }

        // --- Concept note cache check ---
        // For definitional queries in non-cite mode, check if we already have a
        // cached concept note.  If so, inject it as internal memory and skip retrieval.
        var conceptNote: String? = nil
        var useConceptCache = false
        var effectiveTopK = topK
        var usedConceptNotes = 0

        if !detection.matches.isEmpty && !citeRequested {
            if let cached = findFrameworkConceptNote(detection.lookupTerms) {
                conceptNote = cached
                useConceptCache = true
                usedConceptNotes = 1
                effectiveTopK = 0
            } else if policy == .chat && effectiveTopK == 0 {
                if lexicalBoostRequested {
                    effectiveTopK = max(3, config.defaultTopKLibrarian)
                } else {
                    effectiveTopK = min(config.maxTopK, max(3, min(10, config.defaultTopKLibrarian)))
                }
            }
        }

        if lexicalBoostRequested && !useConceptCache && effectiveTopK == 0 && !citeRequested {
            effectiveTopK = max(3, config.defaultTopKLibrarian)
        }

        if intent == .definitional && !citeRequested {
            if let term = extractDefinitionalTerm(query) {
                let normalizedTerm = term.lowercased()
                if let cached = try store.getConceptNote(term: normalizedTerm) {
                    conceptNote = cached.note
                    useConceptCache = true
                    effectiveTopK = 0  // skip retrieval entirely
                    print("Concept cache hit: '\(normalizedTerm)'")
                }
            }
        }

        // Should we ask the model to produce a hidden NOTE: block for caching?
        // Only on the first definitional ask (no cache hit), and only in silent chat mode.
        let shouldGenerateNote = intent == .definitional && !useConceptCache && !citeRequested && effectiveTopK > 0

        // --- Retrieval ---
        let mergedResults: [RetrievalResult]
        let subqueries: [String]
        let retrievalQuery = frameworkDetector.boostedQuery(query, boostTerms: detection.boostTerms)

        if effectiveTopK == 0 {
            subqueries = []
            mergedResults = []
        } else if config.enableQueryDecomposition {
            let decomposer = QueryDecomposer(minSubqueryLength: config.minSubqueryLength)
            let decomposed = decomposer.decompose(query: query, maxSubqueries: config.maxSubqueries)
            subqueries = decomposed

            if !subqueries.isEmpty {
                print("Decomposition: n=\(subqueries.count) subqueries")
                for part in subqueries {
                    print("- \(part)")
                }
            }

            let options = HybridSearchOptions(
                enableSemanticRetrieval: config.enableSemanticRetrieval,
                semanticOnlyIfLexicalWeak: config.semanticOnlyIfLexicalWeak,
                lexicalWeakThreshold: config.lexicalWeakThreshold
            )

            if subqueries.isEmpty {
                mergedResults = try await hybridSearchEngine.search(query: retrievalQuery, topK: effectiveTopK, options: options)
            } else {
                let totalBudget = max(1, effectiveTopK)
                let subqueryCount = min(subqueries.count, config.maxSubqueries)
                let kEach = max(3, totalBudget / (subqueryCount + 1))
                let remainder = totalBudget - (kEach * (subqueryCount + 1))
                let originalLimit = kEach + max(0, remainder)

                var allResults: [[RetrievalResult]] = []

                let originalResults = try await hybridSearchEngine.search(query: retrievalQuery, topK: originalLimit, options: options)
                allResults.append(originalResults)

                var subqueryResults: [[RetrievalResult]] = []
                for subquery in subqueries.prefix(subqueryCount) {
                    let boostedSubquery = frameworkDetector.boostedQuery(subquery, boostTerms: detection.boostTerms)
                    let results = try await hybridSearchEngine.search(query: boostedSubquery, topK: kEach, options: options)
                    subqueryResults.append(results)
                    allResults.append(results)
                }

                var bestByChunk: [String: RetrievalResult] = [:]
                var hitCount: [String: Int] = [:]

                for result in originalResults {
                    let existing = bestByChunk[result.chunk.id]
                    if existing == nil || result.hybridScore > existing!.hybridScore {
                        bestByChunk[result.chunk.id] = result
                    }
                }

                for results in subqueryResults {
                    for result in results {
                        let existing = bestByChunk[result.chunk.id]
                        if existing == nil || result.hybridScore > existing!.hybridScore {
                            bestByChunk[result.chunk.id] = result
                        }
                        hitCount[result.chunk.id, default: 0] += 1
                    }
                }

                var merged: [RetrievalResult] = []
                merged.reserveCapacity(bestByChunk.count)

                for (chunkId, best) in bestByChunk {
                    let hits = hitCount[chunkId] ?? 0
                    let bonus = Float(max(0, hits - 1)) * config.coverageBonus
                    let boosted = RetrievalResult(
                        chunk: best.chunk,
                        document: best.document,
                        bm25Score: best.bm25Score,
                        cosineScore: best.cosineScore,
                        recencyScore: best.recencyScore,
                        priorityBoost: best.priorityBoost,
                        hybridScore: best.hybridScore + bonus
                    )
                    merged.append(boosted)
                }

                merged.sort { $0.hybridScore > $1.hybridScore }
                let bufferLimit = max(1, totalBudget * 2)
                mergedResults = Array(merged.prefix(bufferLimit))
            }
        } else {
            subqueries = []
            let options = HybridSearchOptions(
                enableSemanticRetrieval: config.enableSemanticRetrieval,
                semanticOnlyIfLexicalWeak: config.semanticOnlyIfLexicalWeak,
                lexicalWeakThreshold: config.lexicalWeakThreshold
            )
            mergedResults = try await hybridSearchEngine.search(query: retrievalQuery, topK: effectiveTopK, options: options)
        }

        // --- Context assembly ---
        let contextQuery: String
        if subqueries.isEmpty {
            contextQuery = query
        } else {
            let bulletList = subqueries.map { "- \($0)" }.joined(separator: "\n")
            contextQuery = "\(query)\n\nSubqueries:\n\(bulletList)"
        }

        let context = contextAssembler.build(
            query: contextQuery,
            results: mergedResults,
            tokenBudget: config.tokenBudget
        )

        // --- Reasoning ---
        let reasoningResult = try await reasoner.reason(
            query: query,
            context: context,
            policy: policy,
            citeRequested: citeRequested,
            includeNoteInstruction: shouldGenerateNote,
            conceptNote: conceptNote
        )

        // --- NOTE block extraction & concept note storage ---
        var finalResponse = reasoningResult.response

        if shouldGenerateNote {
            let (cleanResponse, noteText) = extractNoteBlock(from: reasoningResult.response)
            // Only accept the split if the model actually produced a real response
            if !cleanResponse.isEmpty {
                finalResponse = cleanResponse

                if let noteText = noteText, let term = extractDefinitionalTerm(query) {
                    let normalizedTerm = term.lowercased()
                    let sourceChunkIds = context.results.map { $0.chunk.id }
                    do {
                        try store.upsertConceptNote(term: normalizedTerm, note: noteText, chunkIds: sourceChunkIds)
                        print("Concept note stored: '\(normalizedTerm)'")
                    } catch {
                        print("Concept note storage error: \(error)")
                    }
                }
            }
        }

        // --- Distill and persist note ---
        if !context.results.isEmpty && reasoningResult.ccrScore >= config.ccrThreshold {
            let note = distillationEngine.distill(
                query: query,
                answer: finalResponse,
                sources: context.results
            )
            do {
                let stored = try atlasNotePersister.persist(note)
                if stored {
                    print("Saved note: \(note.id)")
                } else {
                    print("Skipped duplicate note")
                }
            } catch {
                print("Note persistence error: \(error)")
            }
        }

        let processingTime = Date().timeIntervalSince(startTime)

            if !detection.matches.isEmpty || topK > resolvedK {
                let names = detection.matches.map { $0.entry.name }
                print("Detected frameworks: \(names.joined(separator: ", "))")
                print("Used concept notes: \(usedConceptNotes)")
                print("Retrieval K: \(effectiveTopK)")
            }

        return QueryResult(
            response: finalResponse,
            context: context,
            ccrScore: reasoningResult.ccrScore,
            processingTime: processingTime,
            showSources: showSources,
            fromConceptCache: useConceptCache
        )
    }

    // MARK: - Conversational Query Processing

    /// Process query with full conversational context
    /// Conversational mode that:
    /// 1. Retrieves AtlasNotes as first-class memory
    /// 2. Includes chat history
    /// 3. Forces synthesis output for broad topics
    /// 4. Distills and saves notes from good responses
    public func processQueryConversational(
        _ query: String,
        conversationId: String? = nil
    ) async throws -> QueryResult {
        let startTime = Date()

        // Use or create conversation
        let convId = conversationId ?? activeConversationId ?? createNewConversation(title: query)
        activeConversationId = convId

        // Classify intent
        let intent = classifyIntent(query)
        let intentString = String(describing: intent).components(separatedBy: ".").last ?? "general"

        // Detect framework matches
        let detection = frameworkDetector.detect(query: query)
        let frameworkDetected = !detection.matches.isEmpty

        // Determine if citations are requested
        let citeRequested = intent == .citeRequested

        // Build execution plan (central authority)
        let plan = executionPlanner.buildPlan(
            query: query,
            intent: intentString,
            frameworkDetected: frameworkDetected,
            citeRequested: citeRequested,
            conversationId: convId
        )

        print("[Librarian] Plan: strategy=\(plan.strategy), initialK=\(plan.initialK), format=\(plan.outputFormat)")

        // Early return for greetings/small talk
        if plan.strategy == .none && intent == .smallTalk {
            let response = "Hi — I'm Librarian. Ask about anything in your indexed files."
            return QueryResult(
                response: response,
                context: RetrievalContext(query: query, results: [], totalTokens: 0, retrievalTime: 0),
                ccrScore: 1.0,
                processingTime: Date().timeIntervalSince(startTime),
                showSources: false,
                fromConceptCache: false
            )
        }

        // Step 1: Get chat history
        var chatHistory: [ChatMessage] = []
        if plan.includeHistory {
            chatHistory = (try? store.getRecentMessages(conversationId: convId, limit: plan.historyTurns * 2)) ?? []
        }

        // Step 2: Search for relevant AtlasNotes (internal memory)
        var atlasNotes: [AtlasNote] = []
        if plan.preferNotes {
            atlasNotes = (try? store.searchAtlasNotes(query: query, limit: 5)) ?? []
            if !atlasNotes.isEmpty {
                print("[Librarian] Found \(atlasNotes.count) relevant notes in memory")
            }
        }

        // Step 3: Retrieve supporting evidence (chunks)
        var retrievalResults: [RetrievalResult] = []
        if plan.initialK > 0 {
            let options = HybridSearchOptions(
                enableSemanticRetrieval: config.enableSemanticRetrieval,
                semanticOnlyIfLexicalWeak: config.semanticOnlyIfLexicalWeak,
                lexicalWeakThreshold: config.lexicalWeakThreshold
            )

            let boostedQuery = frameworkDetector.boostedQuery(query, boostTerms: detection.boostTerms)
            retrievalResults = try await hybridSearchEngine.search(
                query: boostedQuery,
                topK: plan.initialK,
                options: options
            )

            // Limit to finalK
            if retrievalResults.count > plan.finalK {
                retrievalResults = Array(retrievalResults.prefix(plan.finalK))
            }

            print("[Librarian] Retrieved \(retrievalResults.count) evidence chunks")
        }

        // Step 4: Check concept cache for definitional queries
        var conceptNote: String? = nil
        if intent == .definitional && !citeRequested {
            if let term = extractDefinitionalTerm(query) {
                if let cached = try? store.getConceptNote(term: term.lowercased()) {
                    conceptNote = cached.note
                    print("[Librarian] Concept cache hit: '\(term)'")
                }
            }
        }

        // Step 5: Build conversational context
        let contextText = contextAssembler.formatConversationalContext(
            query: query,
            chatHistory: chatHistory,
            atlasNotes: atlasNotes,
            retrievalResults: retrievalResults,
            conceptNote: conceptNote
        )

        // Step 6: Determine output format for prompt
        let outputFormat: ConversationalOutputFormat
        switch plan.outputFormat {
        case .synthesis:
            outputFormat = .synthesis
        case .citation:
            outputFormat = .citation
        case .conversational:
            outputFormat = .conversational
        }

        // Step 7: Build and send prompt
        let hasCodeSources = retrievalResults.contains {
            $0.document.sourceType == .pythonSource || $0.document.sourceType == .swiftSource
        }
        let isDefinitional = intent == .definitional
        let messages = promptBuilder.buildConversationalMessages(
            context: contextText,
            outputFormat: outputFormat,
            hasHistory: !chatHistory.isEmpty,
            hasNotes: !atlasNotes.isEmpty || conceptNote != nil,
            hasEvidence: !retrievalResults.isEmpty,
            hasCodeSources: hasCodeSources,
            isDefinitional: isDefinitional
        )

        let deepSeekResponse = try await deepSeekClient.chat(
            messages: messages,
            temperature: config.temperature,
            maxTokens: config.maxTokens
        )

        // Step 8: Extract NOTE block from DeepSeek output first (internal caching — must
        // happen before the reasoning chain runs so the NOTE is preserved regardless)
        var deepSeekClean = deepSeekResponse
        var extractedNote: String? = nil

        if plan.outputFormat == .synthesis || isDefinitional {
            let (cleanResponse, noteText) = extractNoteBlock(from: deepSeekResponse)
            if !cleanResponse.isEmpty {
                deepSeekClean = cleanResponse
                extractedNote = noteText
            }
        }

        // Phase 11: GPT-5 mini synthesis layer — second embedding pass + final synthesis
        var finalResponse: String
        if config.enableMiniSynthesisLayer && !retrievalResults.isEmpty {
            let enhanced = await reasoningChain.run(
                query: query,
                retrievalResults: retrievalResults,
                deepSeekDraft: deepSeekClean
            )
            finalResponse = enhanced ?? deepSeekClean
        } else {
            finalResponse = deepSeekClean
        }

        // Step 9: Message persistence is handled by the caller (ChatViewModel).
        // Do not save here — saving in both places causes duplicate messages in the DB.

        // Step 10: Distill and save AtlasNote if warranted
        if plan.shouldDistill && !retrievalResults.isEmpty {
            // If we extracted a note from synthesis output, use it
            if let noteText = extractedNote {
                let note = AtlasNote(
                    query: query,
                    summary: noteText,
                    keyConcepts: extractKeyConcepts(from: noteText),
                    sourceChunkIds: retrievalResults.map { $0.chunk.id },
                    retrievalBoost: config.notePriorityBoost
                )
                do {
                    let stored = try atlasNotePersister.persist(note)
                    if stored {
                        print("[Librarian] Saved note from synthesis: \(note.id)")
                    }
                } catch {
                    print("[Librarian] Note save error: \(error)")
                }
            } else {
                // Use standard distillation
                let note = distillationEngine.distill(
                    query: query,
                    answer: finalResponse,
                    sources: retrievalResults
                )
                do {
                    let stored = try atlasNotePersister.persist(note)
                    if stored {
                        print("[Librarian] Distilled and saved note: \(note.id)")
                    }
                } catch {
                    print("[Librarian] Note save error: \(error)")
                }
            }
        }

        // Step 11: Store concept note for definitional queries
        if intent == .definitional && conceptNote == nil && !citeRequested {
            if let term = extractDefinitionalTerm(query) {
                if let noteText = extractedNote {
                    try? store.upsertConceptNote(
                        term: term.lowercased(),
                        note: noteText,
                        chunkIds: retrievalResults.map { $0.chunk.id }
                    )
                    print("[Librarian] Cached concept note: '\(term)'")
                }
            }
        }

        let processingTime = Date().timeIntervalSince(startTime)

        // Build context for return value
        let context = RetrievalContext(
            query: query,
            results: retrievalResults,
            totalTokens: retrievalResults.reduce(0) { $0 + $1.chunk.tokenCount },
            retrievalTime: processingTime
        )

        print("[Librarian] Query complete in \(String(format: "%.2f", processingTime))s")

        return QueryResult(
            response: finalResponse,
            context: context,
            ccrScore: 1.0,  // No CCR validation in conversational mode
            processingTime: processingTime,
            showSources: citeRequested,
            fromConceptCache: conceptNote != nil
        )
    }

    /// Create a new conversation and return its ID
    private func createNewConversation(title: String) -> String {
        let truncatedTitle = title.count > 50 ? String(title.prefix(50)) + "..." : title
        let conversation = Conversation(title: truncatedTitle)
        try? store.insertConversation(conversation)
        return conversation.id
    }

    /// Extract key concepts from text (simple extraction)
    private func extractKeyConcepts(from text: String) -> [String] {
        // Find backtick-quoted terms and capitalized phrases
        var concepts: [String] = []

        // Backtick terms
        let backtickPattern = try? NSRegularExpression(pattern: "`([^`]{2,40})`")
        let range = NSRange(text.startIndex..., in: text)
        backtickPattern?.enumerateMatches(in: text, range: range) { match, _, _ in
            if let matchRange = match?.range(at: 1),
               let swiftRange = Range(matchRange, in: text) {
                concepts.append(String(text[swiftRange]))
            }
        }

        // Capitalized multi-word phrases (2-4 words)
        let capsPattern = try? NSRegularExpression(pattern: "\\b([A-Z][a-z]+(?:\\s+[A-Z][a-z]+){1,3})\\b")
        capsPattern?.enumerateMatches(in: text, range: range) { match, _, _ in
            if let matchRange = match?.range(at: 1),
               let swiftRange = Range(matchRange, in: text) {
                let phrase = String(text[swiftRange])
                if !["The", "And", "But", "For", "With"].contains(phrase.components(separatedBy: " ").first ?? "") {
                    concepts.append(phrase)
                }
            }
        }

        return Array(Set(concepts)).sorted().prefix(12).map { $0 }
    }

    // MARK: - Intent & Routing

    private func resolveTopK(policy: AssistantPolicy, intent: Intent) -> Int {
        switch policy {
        case .chat:
            switch intent {
            case .smallTalk, .general:
                return config.defaultTopKChat
            case .atlasRequested, .citeRequested, .deepFromDocs, .definitional:
                return min(config.maxTopK, max(config.defaultTopKLibrarian, 10))
            }
        case .librarian:
            return min(config.maxTopK, max(config.defaultTopKLibrarian, 1))
        }
    }

    private func classifyIntent(_ query: String) -> Intent {
        let lower = query.lowercased()
        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)

        let smallTalkKeywords = ["hi", "hello", "hey", "sup", "yo", "thanks", "thank you", "how are you"]
        if trimmed.count <= 12 || smallTalkKeywords.contains(where: { trimmed == $0 || trimmed.hasPrefix($0 + " ") }) {
            return .smallTalk
        }

        let citeKeywords = ["cite", "citation", "sources", "show evidence", "quote", "quotes", "evidence"]
        if citeKeywords.contains(where: { trimmed.contains($0) }) {
            return .citeRequested
        }

        let atlasKeywords = [
            "librarian",
            "indexed files",
            "knowledge base",
            "in my files",
            "in my docs",
            "in my documents",
            "in my notes",
            "from my files",
            "from the docs",
            "from the codebase"
        ]
        if atlasKeywords.contains(where: { trimmed.contains($0) }) {
            return .atlasRequested
        }

        let deepFromDocsKeywords = [
            "only from documents",
            "only from the documents",
            "summarize these files",
            "based on the documents",
            "from my files",
            "use my files",
            "use the files",
            "use the documents"
        ]
        if deepFromDocsKeywords.contains(where: { trimmed.contains($0) }) {
            return .deepFromDocs
        }

        // Definitional queries — trigger silent retrieval + concept note caching
        let definitionalPrefixes = [
            "what is ", "what are ", "what was ", "what were ",
            "define ", "explain ", "describe "
        ]
        if definitionalPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
            return .definitional
        }

        return .general
    }

    // MARK: - Concept Note Helpers
    private func findFrameworkConceptNote(_ terms: [String]) -> String? {
        for term in terms {
            let normalized = term.lowercased()
            if let cached = try? store.getConceptNote(term: normalized) {
                return cached.note
            }
        }
        return nil
    }

    /// Extracts the target concept term from a definitional query.
    /// e.g. "what is hybrid retrieval?" → "hybrid retrieval"
    private func extractDefinitionalTerm(_ query: String) -> String? {
        let lower = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        let prefixes = [
            "what is ", "what are ", "what was ", "what were ",
            "define ", "explain ", "describe "
        ]

        for prefix in prefixes {
            if lower.hasPrefix(prefix) {
                var term = String(lower.dropFirst(prefix.count))
                // Strip leading articles
                for article in ["a ", "an ", "the "] {
                    if term.hasPrefix(article) {
                        term = String(term.dropFirst(article.count))
                        break
                    }
                }
                // Strip trailing punctuation and whitespace
                term = term.trimmingCharacters(in: CharacterSet(charactersIn: "?.!,;:"))
                    .trimmingCharacters(in: .whitespaces)
                if term.count >= 2 {
                    return term
                }
            }
        }
        return nil
    }

    /// Extracts a NOTE: block from the tail of a model response.
    /// Returns the cleaned response (without NOTE) and the extracted note text.
    /// If no NOTE: marker is found in the last 15 lines, returns the original response unchanged.
    private func extractNoteBlock(from response: String) -> (cleanResponse: String, note: String?) {
        let lines = response.components(separatedBy: "\n")

        // Search only the tail of the response for the NOTE: marker
        var splitIndex: Int? = nil
        let searchStart = max(0, lines.count - 15)
        for i in stride(from: lines.count - 1, through: searchStart, by: -1) {
            let trimmedLine = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("NOTE:") {
                splitIndex = i
                break
            }
        }

        guard let idx = splitIndex else {
            return (response, nil)
        }

        let cleanResponse = lines[0..<idx].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Collect everything from the NOTE: line onward, strip the "NOTE:" prefix
        var noteLines = Array(lines[idx...])
        noteLines[0] = String(noteLines[0].trimmingCharacters(in: .whitespaces).dropFirst(5)) // drop "NOTE:"
        let noteText = noteLines.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (cleanResponse, noteText.isEmpty ? nil : noteText)
    }

    // MARK: - Conversation Management

    public func createConversation(title: String) throws -> Conversation {
        let conversation = Conversation(title: title)
        try store.insertConversation(conversation)
        return conversation
    }

    public func saveMessage(_ message: ChatMessage) throws {
        try store.insertMessage(message)
    }

    public func getConversations() throws -> [Conversation] {
        return try store.getConversations(limit: 200)
    }

    public func getConversation(id: String) throws -> Conversation? {
        return try store.getConversation(id: id)
    }

    public func getMessages(conversationId: String, limit: Int = 20) throws -> [ChatMessage] {
        return try store.getRecentMessages(conversationId: conversationId, limit: limit)
    }

    public func updateConversationTitle(id: String, title: String) throws {
        try store.updateConversationTitle(id: id, title: title)
    }

    public func touchConversation(id: String) throws {
        try store.updateConversationTimestamp(id: id)
    }

    /// Set active conversation for subsequent queries
    public func setActiveConversation(_ conversationId: String?) {
        activeConversationId = conversationId
    }

    /// Get current active conversation ID
    public func getActiveConversationId() -> String? {
        return activeConversationId
    }
}

private enum Intent {
    case smallTalk
    case general
    case atlasRequested
    case citeRequested
    case deepFromDocs
    case definitional
}

private struct FrameworkEntry: Codable {
    let id: String
    let name: String
    let aliases: [String]
    let description: String
    let priorityTerms: [String]
}

private struct FrameworkRegistry: Codable {
    let entries: [FrameworkEntry]

    static func load(from path: String) -> FrameworkRegistry {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else {
            return FrameworkRegistry(entries: [])
        }
        if let decoded = try? JSONDecoder().decode(FrameworkRegistry.self, from: data) {
            return decoded
        }
        return FrameworkRegistry(entries: [])
    }
}

private struct FrameworkMatch {
    let entry: FrameworkEntry
    let matchedTerm: String
}

private struct FrameworkDetection {
    let matches: [FrameworkMatch]
    let boostTerms: [String]
    let lookupTerms: [String]
}

private final class FrameworkDetector {
    private let registry: FrameworkRegistry

    init(registry: FrameworkRegistry) {
        self.registry = registry
    }

    func detect(query: String) -> FrameworkDetection {
        let lowerQuery = query.lowercased()
        var matches: [FrameworkMatch] = []
        var boostTerms: [String] = []
        var lookupTerms: [String] = []

        for entry in registry.entries {
            let candidates = uniqueOrdered([entry.name] + entry.aliases + entry.priorityTerms)
            var matched: String? = nil
            for term in candidates {
                let lowerTerm = term.lowercased()
                if lowerTerm.isEmpty { continue }
                if lowerQuery.contains(lowerTerm) {
                    matched = term
                    break
                }
            }
            if let matched = matched {
                matches.append(FrameworkMatch(entry: entry, matchedTerm: matched))
                boostTerms.append(contentsOf: entry.aliases)
                boostTerms.append(contentsOf: entry.priorityTerms)
                lookupTerms.append(entry.name)
                lookupTerms.append(contentsOf: entry.aliases)
            }
        }

        let dedupBoost = uniqueOrdered(boostTerms)
        let dedupLookup = uniqueOrdered(lookupTerms)

        return FrameworkDetection(
            matches: matches,
            boostTerms: dedupBoost,
            lookupTerms: dedupLookup
        )
    }

    func boostedQuery(_ query: String, boostTerms: [String]) -> String {
        guard !boostTerms.isEmpty else { return query }
        let lowerQuery = query.lowercased()
        let toAdd = boostTerms.filter { term in
            let lowerTerm = term.lowercased()
            return !lowerTerm.isEmpty && !lowerQuery.contains(lowerTerm)
        }
        if toAdd.isEmpty { return query }
        return query + " " + toAdd.joined(separator: " ")
    }

    private func uniqueOrdered(_ items: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for item in items {
            let key = item.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty { continue }
            let lowered = key.lowercased()
            if !seen.contains(lowered) {
                seen.insert(lowered)
                out.append(key)
            }
        }
        return out
    }
}

private struct TriggerEntry: Codable {
    let term: String
    let score: Double
}

private struct TriggerRegistry: Codable {
    let triggers: [TriggerEntry]

    static func load(from path: String) -> TriggerRegistry {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultRegistry()
        }

        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else {
            return defaultRegistry()
        }
        if let decoded = try? JSONDecoder().decode(TriggerRegistry.self, from: data) {
            return decoded
        }
        if let wrapped = try? JSONDecoder().decode(TriggerWrapper.self, from: data) {
            return TriggerRegistry(triggers: wrapped.triggers)
        }
        return defaultRegistry()
    }

    func intensity(for query: String) -> Double {
        let lower = query.lowercased()
        var total: Double = 0
        for entry in triggers {
            if lower.contains(entry.term.lowercased()) {
                total += entry.score
            }
        }
        return total
    }

    func topK(for intensity: Double) -> Int {
        // Any trigger match increases retrieval depth.
        switch intensity {
        case ..<1: return 0       // Only true small talk gets 0
        case ..<5: return 10      // Light match: still retrieve 10
        case ..<15: return 20     // Moderate match: retrieve 20
        case ..<30: return 30     // Strong match: retrieve 30
        default: return 50        // Very strong: synthesis mode, get 50
        }
    }

    private struct TriggerWrapper: Codable {
        let triggers: [TriggerEntry]
    }

    private static func defaultRegistry() -> TriggerRegistry {
        TriggerRegistry(
            triggers: [
                TriggerEntry(term: "define", score: 10),
                TriggerEntry(term: "explain", score: 10),
                TriggerEntry(term: "summarize", score: 9),
                TriggerEntry(term: "architecture", score: 12),
                TriggerEntry(term: "implementation", score: 12),
                TriggerEntry(term: "retrieval", score: 13),
                TriggerEntry(term: "embedding", score: 13),
                TriggerEntry(term: "citation", score: 11),
                TriggerEntry(term: "database", score: 12),
                TriggerEntry(term: "swift", score: 10),
                TriggerEntry(term: "python", score: 10)
            ]
        )
    }
}

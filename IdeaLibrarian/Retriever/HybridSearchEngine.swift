import Foundation

public class HybridSearchEngine {
    private let store: SQLiteStore
    private let lexicalRetriever: LexicalRetriever
    private let semanticRetriever: SemanticRetriever
    private let config: Configuration

    public init(
        store: SQLiteStore,
        lexicalRetriever: LexicalRetriever,
        semanticRetriever: SemanticRetriever,
        config: Configuration
    ) {
        self.store = store
        self.lexicalRetriever = lexicalRetriever
        self.semanticRetriever = semanticRetriever
        self.config = config
    }

    public func search(query: String, topK: Int) async throws -> [RetrievalResult] {
        let options = HybridSearchOptions(
            enableSemanticRetrieval: config.enableSemanticRetrieval,
            semanticOnlyIfLexicalWeak: config.semanticOnlyIfLexicalWeak,
            lexicalWeakThreshold: config.lexicalWeakThreshold
        )
        return try await search(query: query, topK: topK, options: options)
    }

    public func hasLexicalMatches(query: String, limit: Int = 5) throws -> Bool {
        let lexicalResults = try lexicalRetriever.search(query: query, limit: limit)
        return !lexicalResults.isEmpty
    }

    public func search(query: String, topK: Int, options: HybridSearchOptions) async throws -> [RetrievalResult] {
        if topK <= 0 { return [] }

        // Retrieve MORE candidates to allow quality filtering
        let candidateMultiplier = 4  // Get 4x candidates, filter to topK
        let candidateLimit = topK * candidateMultiplier

        let lexicalScores = try lexicalRetriever.search(query: query, limit: candidateLimit)
        let maxLexical = lexicalScores.map { $0.score }.max() ?? 0.0

        let shouldRunSemantic: Bool = {
            guard options.enableSemanticRetrieval else { return false }
            if !options.semanticOnlyIfLexicalWeak { return true }
            return maxLexical < options.lexicalWeakThreshold
        }()

        let semanticScores: [(chunkId: String, score: Float)]
        if shouldRunSemantic {
            semanticScores = try await semanticRetriever.search(query: query, limit: candidateLimit)
        } else {
            semanticScores = []
        }

        // Merge results using hybrid scoring
        var hybridResults = try mergeResults(
            lexicalScores: Dictionary(uniqueKeysWithValues: lexicalScores),
            semanticScores: Dictionary(uniqueKeysWithValues: semanticScores)
        )

        // CRITICAL: Apply quality filter to remove garbage chunks
        hybridResults = applyQualityFilter(hybridResults)

        // Apply diversity filter and take top K
        let diverseResults = applyDiversityFilter(hybridResults, maxPerDocument: config.maxChunksPerDocument)
        let topResults = Array(diverseResults.prefix(topK))

        return topResults
    }

    // MARK: - Quality Filtering

    /// Filter out low-quality chunks and boost high-quality ones
    /// This is critical so Librarian avoids low-signal chunks.
    private func applyQualityFilter(_ results: [RetrievalResult]) -> [RetrievalResult] {
        var filtered: [RetrievalResult] = []

        for result in results {
            let content = result.chunk.content
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

            // REJECT: Question-only chunks with little content
            if isQuestionOnlyChunk(trimmed, tokenCount: result.chunk.tokenCount) {
                continue
            }

            // REJECT: Ultra-short chunks (less than 50 tokens of actual content)
            if result.chunk.tokenCount < 50 {
                continue
            }

            // Calculate quality boost based on content type and substance
            let qualityBoost = calculateQualityBoost(result)

            // Create boosted result
            let boostedResult = RetrievalResult(
                chunk: result.chunk,
                document: result.document,
                bm25Score: result.bm25Score,
                cosineScore: result.cosineScore,
                recencyScore: result.recencyScore,
                priorityBoost: result.priorityBoost + qualityBoost,
                hybridScore: result.hybridScore + qualityBoost
            )

            filtered.append(boostedResult)
        }

        // Re-sort by boosted score
        filtered.sort { $0.hybridScore > $1.hybridScore }

        return filtered
    }

    /// Detect question-only chunks that provide no real information
    private func isQuestionOnlyChunk(_ content: String, tokenCount: Int) -> Bool {
        // If it ends with a question mark and is short, likely a question
        if content.hasSuffix("?") && tokenCount < 100 {
            return true
        }

        // Count question vs statement lines
        let lines = content.split(separator: "\n")
        if lines.isEmpty { return true }

        let questionLines = lines.filter {
            $0.trimmingCharacters(in: .whitespaces).hasSuffix("?")
        }

        // If more than 60% of lines are questions, reject
        if questionLines.count > 0 && Float(questionLines.count) / Float(lines.count) > 0.6 {
            return true
        }

        return false
    }

    /// Calculate quality boost based on content type and substance
    private func calculateQualityBoost(_ result: RetrievalResult) -> Float {
        var boost: Float = 0.0

        // Boost by content type (stage2 and conclusions are most valuable)
        switch result.chunk.contentType {
        case .stage2:
            boost += 0.4  // Analytical content - highest value
        case .conclusion:
            boost += 0.35  // Synthesized insights
        case .stage1:
            boost += 0.2   // Initial analysis
        case .question, .nextQuestion:
            boost -= 0.3   // Questions are less useful for answering
        case .contradiction:
            boost += 0.25  // Contradictions show nuance
        // Source code chunk types (Python + Swift)
        case .functionDef:
            boost += 0.40  // Individual function/method - most precise retrieval unit
        case .classDef:
            boost += 0.35  // Class/enum/protocol declaration - high contextual value
        case .structDef:
            boost += 0.35  // Swift struct - same value as classDef
        case .extensionDef:
            boost += 0.35  // Swift extension - high value, adds functionality to types
        case .moduleCode:
            boost += 0.20  // Module-level code
        case .importBlock:
            boost += 0.05  // Import declarations - low standalone value
        }

        boost += folderPriorityBoost(for: result.document.sourcePath)

        // Boost for substantial content (more tokens = more substance)
        if result.chunk.tokenCount > 300 {
            boost += 0.25
        } else if result.chunk.tokenCount > 200 {
            boost += 0.15
        }

        // Boost if content contains definitional patterns
        let content = result.chunk.content.lowercased()
        let definitionalPatterns = ["is defined as", "means that", "refers to", "we claim", "the key insight", "fundamentally", "in essence"]
        for pattern in definitionalPatterns {
            if content.contains(pattern) {
                boost += 0.1
                break
            }
        }

        return boost
    }

    private func folderPriorityBoost(for sourcePath: String) -> Float {
        if sourcePath.lowercased().contains("/projects/") {
            return 0.30
        }

        let normalizedPath = "/" + sourcePath.lowercased() + "/"
        let folderWeights = config.folderPriorityWeights
        guard !folderWeights.isEmpty else { return 0.0 }

        let match = folderWeights
            .sorted { $0.key.count > $1.key.count }
            .first { key, _ in
                let normalizedKey = key.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return !normalizedKey.isEmpty && normalizedPath.contains("/\(normalizedKey)/")
            }

        guard let weight = match?.value else {
            return 0.0
        }

        return max(0.0, weight - 1.0) * 0.5
    }

    private func mergeResults(
        lexicalScores: [String: Float],
        semanticScores: [String: Float]
    ) throws -> [RetrievalResult] {
        // Get all unique chunk IDs
        let allChunkIds = Set(lexicalScores.keys).union(semanticScores.keys)

        var results: [RetrievalResult] = []

        for chunkId in allChunkIds {
            guard let chunk = try store.getChunk(id: chunkId),
                  let document = try store.getDocument(id: chunk.documentId) else {
                continue
            }

            let bm25Score = lexicalScores[chunkId] ?? 0.0
            let cosineScore = semanticScores[chunkId] ?? 0.0
            let recencyScore = calculateRecencyScore(date: document.createdAt)
            let priorityBoost = getPriorityBoost(document: document)

            // Hybrid scoring formula: α*BM25 + β*cosine + γ*recency + priority_boost
            let hybridScore = config.alphaBM25 * bm25Score +
                            config.betaCosine * cosineScore +
                            config.gammaRecency * recencyScore +
                            priorityBoost

            let result = RetrievalResult(
                chunk: chunk,
                document: document,
                bm25Score: bm25Score,
                cosineScore: cosineScore,
                recencyScore: recencyScore,
                priorityBoost: priorityBoost,
                hybridScore: hybridScore
            )

            results.append(result)
        }

        // Sort by hybrid score descending
        results.sort { $0.hybridScore > $1.hybridScore }

        return results
    }

    private func calculateRecencyScore(date: Date) -> Float {
        // Exponential decay: exp(-days_since_creation / 365)
        // 1-year half-life
        let daysSinceCreation = Date().timeIntervalSince(date) / (24 * 60 * 60)
        return exp(-Float(daysSinceCreation) / 365.0)
    }

    private func getPriorityBoost(document: Document) -> Float {
        // Distilled notes get priority boost.
        if document.sourceType == .atlasNote {
            return config.notePriorityBoost
        }
        return 0.0
    }

    private func applyDiversityFilter(_ results: [RetrievalResult], maxPerDocument: Int) -> [RetrievalResult] {
        var documentCounts: [String: Int] = [:]
        var filtered: [RetrievalResult] = []

        for result in results {
            // Python and Swift source files contain small semantic units (functions/types),
            // so allow more chunks per file to surface relevant code across a module.
            let isCodeSource = result.document.sourceType == .pythonSource
                            || result.document.sourceType == .swiftSource
            let limit = isCodeSource ? 4 : maxPerDocument
            let count = documentCounts[result.document.id] ?? 0
            if count < limit {
                filtered.append(result)
                documentCounts[result.document.id] = count + 1
            }
        }

        return filtered
    }

    // MARK: - Note-Aware Search

    /// Search with distilled notes merged as first-class retrieval results.
    /// Notes are boosted and interleaved with chunk results
    public func searchWithNotes(
        query: String,
        topK: Int,
        noteLimit: Int = 5,
        noteBoost: Float = 1.5,
        options: HybridSearchOptions
    ) async throws -> (chunks: [RetrievalResult], notes: [AtlasNote]) {
        // Get chunk results
        let chunkResults = try await search(query: query, topK: topK, options: options)

        // Search distilled notes.
        let notes = try store.searchAtlasNotes(query: query, limit: noteLimit)

        return (chunks: chunkResults, notes: notes)
    }

    /// Convert a distilled note to `RetrievalResult` for unified ranking.
    /// This allows notes to be ranked alongside chunks
    public func noteToRetrievalResult(_ note: AtlasNote) throws -> RetrievalResult? {
        // Create a virtual document for the note
        let document = Document(
            id: "note_\(note.id)",
            sourceType: .atlasNote,
            sourcePath: "atlas_note://\(note.id)",
            worldId: nil,
            evolutionRunId: nil,
            createdAt: note.createdAt,
            indexedAt: note.createdAt,
            metadata: ["query": note.query]
        )

        // Create a virtual chunk from the note summary
        let chunk = Chunk(
            id: "note_chunk_\(note.id)",
            documentId: document.id,
            chunkIndex: 0,
            contentType: .conclusion,
            content: note.summary,
            tokenCount: note.summary.count / 4  // Rough estimate
        )

        return RetrievalResult(
            chunk: chunk,
            document: document,
            bm25Score: 0.8,  // High base score for notes
            cosineScore: 0.8,
            recencyScore: calculateRecencyScore(date: note.createdAt),
            priorityBoost: note.retrievalBoost,
            hybridScore: 0.8 + note.retrievalBoost  // Notes get significant boost
        )
    }
}

public struct HybridSearchOptions {
    public let enableSemanticRetrieval: Bool
    public let semanticOnlyIfLexicalWeak: Bool
    public let lexicalWeakThreshold: Float

    public init(enableSemanticRetrieval: Bool, semanticOnlyIfLexicalWeak: Bool, lexicalWeakThreshold: Float) {
        self.enableSemanticRetrieval = enableSemanticRetrieval
        self.semanticOnlyIfLexicalWeak = semanticOnlyIfLexicalWeak
        self.lexicalWeakThreshold = lexicalWeakThreshold
    }
}

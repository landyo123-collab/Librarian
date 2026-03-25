import Foundation

public class ReasoningChain {
    private let miniClient: OpenAIChatClient
    private let semanticRetriever: SemanticRetriever
    private let store: SQLiteStore
    private let promptBuilder: PromptBuilder
    private let config: Configuration

    public init(
        miniClient: OpenAIChatClient,
        semanticRetriever: SemanticRetriever,
        store: SQLiteStore,
        promptBuilder: PromptBuilder,
        config: Configuration
    ) {
        self.miniClient = miniClient
        self.semanticRetriever = semanticRetriever
        self.store = store
        self.promptBuilder = promptBuilder
        self.config = config
    }

    /// Run the GPT-5 mini synthesis layer.
    /// Returns the enhanced response, or nil if any step fails (caller falls back to DeepSeek draft).
    public func run(
        query: String,
        retrievalResults: [RetrievalResult],
        deepSeekDraft: String
    ) async -> String? {
        do {
            // Second embedding pass: use DeepSeek's draft to surface additional
            // chunks from the 80k index that the original query didn't retrieve.
            let additionalChunks = await fetchAdditionalChunks(
                draft: deepSeekDraft,
                existingResults: retrievalResults
            )

            let messages = promptBuilder.buildMiniSynthesisMessages(
                query: query,
                originalSources: retrievalResults,
                additionalSources: additionalChunks,
                deepSeekDraft: deepSeekDraft
            )

            let finalResponse = try await miniClient.chat(
                messages: messages,
                temperature: 0.5,
                maxTokens: config.gptMiniMaxTokens
            )

            // Treat empty string the same as a failure — reasoning models can exhaust
            // their token budget on internal reasoning and return "" without throwing.
            guard !finalResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                print("[ReasoningChain] GPT-5 mini returned empty response (token budget exhausted?). Falling back to DeepSeek.")
                return nil
            }

            print("[ReasoningChain] GPT-5 mini synthesis complete. Additional chunks used: \(additionalChunks.count)")
            return finalResponse

        } catch {
            print("[ReasoningChain] GPT-5 mini layer failed: \(error.localizedDescription). Falling back to DeepSeek.")
            return nil
        }
    }

    // MARK: - Second Embedding Pass

    /// Uses the first 400 characters of DeepSeek's draft as a semantic query
    /// to find chunks from the 80k index that the original retrieval missed.
    private func fetchAdditionalChunks(
        draft: String,
        existingResults: [RetrievalResult]
    ) async -> [RetrievalResult] {
        let searchQuery = String(draft.prefix(400))
        let existingIds = Set(existingResults.map { $0.chunk.id })

        do {
            // Over-fetch to allow for dedup against already-retrieved chunks
            let semanticResults = try await semanticRetriever.search(
                query: searchQuery,
                limit: config.maxSecondPassChunks * 3
            )

            var additional: [RetrievalResult] = []

            for result in semanticResults {
                guard !existingIds.contains(result.chunkId) else { continue }

                guard let chunk = try? store.getChunk(id: result.chunkId),
                      let document = try? store.getDocument(id: chunk.documentId) else {
                    continue
                }

                // Skip ultra-short chunks — same quality floor as HybridSearchEngine
                guard chunk.tokenCount >= 50 else { continue }

                let retrievalResult = RetrievalResult(
                    chunk: chunk,
                    document: document,
                    bm25Score: 0.0,
                    cosineScore: result.score,
                    recencyScore: 0.0,
                    priorityBoost: 0.0,
                    hybridScore: result.score
                )
                additional.append(retrievalResult)

                if additional.count >= config.maxSecondPassChunks { break }
            }

            if !additional.isEmpty {
                print("[ReasoningChain] Second pass: \(additional.count) new chunks found beyond original retrieval")
            }

            return additional

        } catch {
            print("[ReasoningChain] Second pass retrieval failed: \(error.localizedDescription)")
            return []
        }
    }
}

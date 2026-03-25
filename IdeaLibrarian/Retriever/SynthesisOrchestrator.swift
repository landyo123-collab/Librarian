import Foundation

/// Orchestrates synthesis-mode retrieval for broad-topic queries
/// Handles candidate pool expansion, folder weighting, diversity enforcement, and filtering
public class SynthesisOrchestrator {
    private let hybridSearchEngine: HybridSearchEngine
    private let evidenceMiner: EvidenceMiner
    private let statsService: StatsService
    private let config: Configuration

    public struct SynthesisResult {
        public let candidates: [RetrievalResult]  // Full candidate pool (K_candidates)
        public let filtered: [RetrievalResult]    // After content filtering
        public let final: [RetrievalResult]       // Final selection (finalK)
        public let evidence: [EvidenceMiner.EvidenceSnippet]
        public let stats: StatsService.CorpusStats?
        public let debugInfo: SynthesisDebugInfo
    }

    public struct SynthesisDebugInfo {
        public let strategy: RetrievalStrategy
        public let candidatesRequested: Int
        public let candidatesRetrieved: Int
        public let filteredCount: Int
        public let finalK: Int
        public let folderDistribution: [String: Int]
        public let enforceHighPriorityQuota: Int
        public let topic: String?
        public let retrievalTime: TimeInterval
    }

    public init(
        hybridSearchEngine: HybridSearchEngine,
        statsService: StatsService,
        config: Configuration
    ) {
        self.hybridSearchEngine = hybridSearchEngine
        self.evidenceMiner = EvidenceMiner()
        self.statsService = statsService
        self.config = config
    }

    /// Perform synthesis retrieval for a broad-topic query
    public func synthesize(
        query: String,
        topic: String?,
        finalK: Int = 20,
        kCandidates: Int = 120
    ) async throws -> SynthesisResult {
        let startTime = Date()

        // Step 1: Retrieve large candidate pool
        let candidates = try await hybridSearchEngine.search(
            query: query,
            topK: kCandidates
        )

        // Step 2: Apply folder weighting and diversity (already done in HybridSearchEngine via config)
        // But we may need to re-rank or apply additional filtering
        let withFolderWeights = applyFolderWeighting(candidates)

        // Step 3: Enforce diversity quota (min from high-priority folders)
        let diversified = enforceDiversityQuota(withFolderWeights, finalK: finalK)

        // Step 4: Filter out low-content question-only chunks
        let filtered = filterQuestionOnlyChunks(diversified)

        // Step 5: Select final K
        let finalResults = Array(filtered.prefix(finalK))

        // Step 6: Mine evidence snippets
        let evidence = evidenceMiner.mineEvidence(
            from: candidates,
            topic: topic ?? query,
            maxSnippets: 30
        )

        // Step 7: Get corpus stats
        let stats = topic.flatMap { statsService.getStats(for: $0) }

        // Calculate folder distribution for debug info
        var folderDist: [String: Int] = [:]
        for result in finalResults {
            let folder = extractFolder(from: result.document.sourcePath) ?? "root"
            folderDist[folder, default: 0] += 1
        }

        let highPriorityFolders = prioritizedFolders()
        let highPriorityCount = folderDist.reduce(into: 0) { partial, entry in
            if highPriorityFolders.contains(entry.key) {
                partial += entry.value
            }
        }

        let debugInfo = SynthesisDebugInfo(
            strategy: .synthesis,
            candidatesRequested: kCandidates,
            candidatesRetrieved: candidates.count,
            filteredCount: filtered.count,
            finalK: finalResults.count,
            folderDistribution: folderDist,
            enforceHighPriorityQuota: highPriorityCount,
            topic: topic,
            retrievalTime: Date().timeIntervalSince(startTime)
        )

        return SynthesisResult(
            candidates: candidates,
            filtered: filtered,
            final: finalResults,
            evidence: evidence,
            stats: stats,
            debugInfo: debugInfo
        )
    }

    /// Apply folder weighting to results
    private func applyFolderWeighting(_ results: [RetrievalResult]) -> [RetrievalResult] {
        let folderWeights = config.folderPriorityWeights

        var weighted = results.map { result -> RetrievalResult in
            let folder = extractFolder(from: result.document.sourcePath) ?? "root"
            let weight = folderWeights[folder] ?? 1.0

            let folderBoost = max(0, Float(weight - 1.0) * 0.5)
            let newScore = result.hybridScore + folderBoost

            return RetrievalResult(
                chunk: result.chunk,
                document: result.document,
                bm25Score: result.bm25Score,
                cosineScore: result.cosineScore,
                recencyScore: result.recencyScore,
                priorityBoost: result.priorityBoost + folderBoost,
                hybridScore: newScore
            )
        }

        // Re-sort by weighted score
        weighted.sort { $0.hybridScore > $1.hybridScore }
        return weighted
    }

    /// Enforce diversity quota: ensure min(10, K/2) from high-priority folders
    private func enforceDiversityQuota(
        _ results: [RetrievalResult],
        finalK: Int
    ) -> [RetrievalResult] {
        guard config.enforceFolderPriorityDiversity else {
            return results
        }

        let quota = min(10, finalK / 2)
        var output: [RetrievalResult] = []
        var highPriorityCount = 0

        let highPriorityFolders = prioritizedFolders()
        guard !highPriorityFolders.isEmpty else {
            return Array(results.prefix(finalK))
        }

        // First pass: collect high-priority until quota
        for result in results {
            let folder = extractFolder(from: result.document.sourcePath) ?? "root"
            if highPriorityFolders.contains(folder) && highPriorityCount < quota {
                output.append(result)
                highPriorityCount += 1
            }
        }

        // Second pass: fill remaining slots with other results
        for result in results {
            if output.count >= finalK {
                break
            }
            if !output.contains(where: { $0.chunk.id == result.chunk.id }) {
                output.append(result)
            }
        }

        return output
    }

    /// Filter out low-content question-only chunks
    private func filterQuestionOnlyChunks(_ results: [RetrievalResult]) -> [RetrievalResult] {
        return results.filter { result in
            let content = result.chunk.content
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

            // Remove if it's question-only with low token count
            if trimmed.hasSuffix("?") && result.chunk.tokenCount < 50 {
                return false
            }

            // Remove if mostly questions
            let lines = trimmed.split(separator: "\n")
            let questionLines = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasSuffix("?") }
            if questionLines.count > lines.count / 2 && lines.count > 2 {
                return false
            }

            // Keep chunks with declarative content
            return true
        }
    }

    /// Extract folder from document path
    private func extractFolder(from path: String) -> String? {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        if components.count >= 2 {
            return components[components.count - 2]
        }
        return nil
    }

    private func prioritizedFolders() -> Set<String> {
        let sorted = config.folderPriorityWeights
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .prefix(2)
            .map(\.key)
        return Set(sorted)
    }
}

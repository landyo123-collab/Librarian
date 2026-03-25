import Foundation

public class TokenBudgetManager {
    public init() {}

    public func selectChunks(results: [RetrievalResult], budget: Int) -> [RetrievalResult] {
        var selected: [RetrievalResult] = []
        var currentTokens = 0

        for result in results {
            let chunkTokens = result.chunk.tokenCount

            // Check if adding this chunk would exceed budget
            if currentTokens + chunkTokens > budget {
                break
            }

            selected.append(result)
            currentTokens += chunkTokens
        }

        return selected
    }

    public func estimateResponseTokens(contextTokens: Int, totalBudget: Int) -> Int {
        // Reserve tokens for response (typically 2000-4000)
        return totalBudget - contextTokens
    }
}

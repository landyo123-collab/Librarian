import Foundation

public class LexicalRetriever {
    private let store: SQLiteStore

    public init(store: SQLiteStore) {
        self.store = store
    }

    public func search(query: String, limit: Int = 50) throws -> [(chunkId: String, score: Float)] {
        // Use FTS5 for full-text search with BM25 ranking
        let chunkIds = try store.searchChunks(query: query, limit: limit)

        // FTS5 returns results already ranked by BM25
        // Assign normalized scores (1.0 for best, decreasing)
        var results: [(String, Float)] = []
        for (index, chunkId) in chunkIds.enumerated() {
            // Normalize BM25 score: exponential decay from 1.0
            let normalizedScore = exp(-Float(index) / Float(limit / 2))
            results.append((chunkId, normalizedScore))
        }

        return results
    }
}

import Foundation

public class SemanticRetriever {
    private let store: SQLiteStore
    private let embeddingProvider: EmbeddingProvider

    public init(store: SQLiteStore, embeddingProvider: EmbeddingProvider) {
        self.store = store
        self.embeddingProvider = embeddingProvider
    }

    public func search(query: String, limit: Int = 50) async throws -> [(chunkId: String, score: Float)] {
        // Generate embedding for query
        let queryEmbedding = try await embeddingProvider.embed(text: query)

        // Get all embeddings from database
        let allEmbeddings = try store.getAllEmbeddings()

        // Calculate cosine similarity for each
        var scores: [(String, Float)] = []
        for embedding in allEmbeddings {
            let similarity = cosineSimilarity(queryEmbedding, embedding.embedding)
            scores.append((embedding.chunkId, similarity))
        }

        // Sort by similarity descending and take top K
        scores.sort { $0.1 > $1.1 }
        return Array(scores.prefix(limit))
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0.0 }

        var dotProduct: Float = 0.0
        var magnitudeA: Float = 0.0
        var magnitudeB: Float = 0.0

        for i in 0..<a.count {
            dotProduct += a[i] * b[i]
            magnitudeA += a[i] * a[i]
            magnitudeB += b[i] * b[i]
        }

        magnitudeA = sqrt(magnitudeA)
        magnitudeB = sqrt(magnitudeB)

        guard magnitudeA > 0 && magnitudeB > 0 else { return 0.0 }

        return dotProduct / (magnitudeA * magnitudeB)
    }
}

import Foundation

public class EmbeddingProvider {
    private let apiKey: String
    private let model: String
    private let endpoint = "https://api.openai.com/v1/embeddings"
    private let session: URLSession
    private let maxBatchSize: Int
    private let maxTokensPerBatch: Int

    public init(
        apiKey: String,
        model: String = "text-embedding-3-small",
        maxBatchSize: Int = 50,
        maxTokensPerBatch: Int = 6000
    ) {
        self.apiKey = apiKey
        self.model = model
        self.maxBatchSize = maxBatchSize
        self.maxTokensPerBatch = maxTokensPerBatch

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    public func embed(text: String) async throws -> [Float] {
        let results = try await embedBatch(texts: [text])
        guard let embedding = results.first else {
            throw EmbeddingError.emptyResponse
        }
        return embedding
    }

    /// Hard limit for the embedding model (text-embedding-3-small: 8192 tokens).
    /// Code tokenizes at ~1.5 chars/token (vs ~4 for English), so we use a
    /// conservative 8 000-char cap: ~5 000 tokens for code, ~2 000 for English.
    /// Both are safely under 8 192 for all content types.
    private let maxCharsPerText = 8_000

    private func truncateForEmbedding(_ text: String) -> String {
        guard text.count > maxCharsPerText else { return text }
        return String(text.prefix(maxCharsPerText))
    }

    public func embedBatch(texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        var allEmbeddings: [[Float]] = []

        var currentBatch: [String] = []
        currentBatch.reserveCapacity(maxBatchSize)
        var currentTokens = 0

        for rawText in texts {
            let text = truncateForEmbedding(rawText)
            let estimatedTokens = estimateTokens(text)
            let wouldExceedSize = currentBatch.count >= maxBatchSize
            let wouldExceedTokens = currentTokens + estimatedTokens > maxTokensPerBatch

            if !currentBatch.isEmpty && (wouldExceedSize || wouldExceedTokens) {
                let embeddings = try await sendEmbeddingRequest(texts: currentBatch)
                allEmbeddings.append(contentsOf: embeddings)
                currentBatch.removeAll(keepingCapacity: true)
                currentTokens = 0
            }

            currentBatch.append(text)
            currentTokens += estimatedTokens
        }

        if !currentBatch.isEmpty {
            let embeddings = try await sendEmbeddingRequest(texts: currentBatch)
            allEmbeddings.append(contentsOf: embeddings)
        }

        return allEmbeddings
    }

    private func sendEmbeddingRequest(texts: [String]) async throws -> [[Float]] {
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let requestBody: [String: Any] = [
            "model": model,
            "input": texts,
            "encoding_format": "float"
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw EmbeddingError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw EmbeddingError.apiError(statusCode: httpResponse.statusCode, message: errorMessage)
        }

        let embeddingResponse = try JSONDecoder().decode(OpenAIEmbeddingResponse.self, from: data)

        return embeddingResponse.data
            .sorted { $0.index < $1.index }
            .map { $0.embedding }
    }

    private func estimateTokens(_ text: String) -> Int {
        return max(1, text.count / 4)
    }
}

// MARK: - OpenAI API Response Models

private struct OpenAIEmbeddingResponse: Codable {
    let object: String
    let data: [EmbeddingData]
    let model: String
    let usage: Usage

    struct EmbeddingData: Codable {
        let object: String
        let index: Int
        let embedding: [Float]
    }

    struct Usage: Codable {
        let promptTokens: Int
        let totalTokens: Int

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case totalTokens = "total_tokens"
        }
    }
}

public enum EmbeddingError: LocalizedError {
    case emptyResponse
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "Empty response from embedding API"
        case .invalidResponse:
            return "Invalid response from embedding API"
        case .apiError(let statusCode, let message):
            return "Embedding API error (\(statusCode)): \(message)"
        }
    }
}

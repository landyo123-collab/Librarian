import Foundation

public class DeepSeekClient {
    private let apiKey: String
    private let model: String
    private let endpoint = "https://api.deepseek.com/v1/chat/completions"
    private let session: URLSession

    public init(apiKey: String, model: String = "deepseek-chat") {
        self.apiKey = apiKey
        self.model = model

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    public func chat(
        messages: [ChatCompletionMessage],
        temperature: Float = 0.7,
        maxTokens: Int = 4000
    ) async throws -> String {
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        var requestBody: [String: Any] = [
            "model": model,
            "messages": messages.map { $0.toDictionary() },
            "max_tokens": maxTokens
        ]
        // deepseek-reasoner does not accept temperature
        if !model.contains("reasoner") {
            requestBody["temperature"] = temperature
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepSeekError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw DeepSeekError.apiError(statusCode: httpResponse.statusCode, message: errorMessage)
        }

        let chatResponse = try JSONDecoder().decode(DeepSeekChatResponse.self, from: data)

        guard let firstChoice = chatResponse.choices.first,
              let content = firstChoice.message.content else {
            throw DeepSeekError.emptyResponse
        }

        return content
    }
}

// MARK: - Request Models

public struct ChatCompletionMessage {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }

    func toDictionary() -> [String: String] {
        return ["role": role, "content": content]
    }
}

// MARK: - Response Models

private struct DeepSeekChatResponse: Codable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [Choice]
    let usage: Usage

    struct Choice: Codable {
        let index: Int
        let message: Message
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Message: Codable {
        let role: String
        let content: String?
    }

    struct Usage: Codable {
        let promptTokens: Int
        let completionTokens: Int
        let totalTokens: Int

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }
}

public enum DeepSeekError: LocalizedError {
    case emptyResponse
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "Empty response from DeepSeek API"
        case .invalidResponse:
            return "Invalid response from DeepSeek API"
        case .apiError(let statusCode, let message):
            return "DeepSeek API error (\(statusCode)): \(message)"
        }
    }
}

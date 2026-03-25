import Foundation

public class OpenAIChatClient {
    private let apiKey: String
    private let model: String
    private let endpoint = "https://api.openai.com/v1/chat/completions"
    private let session: URLSession

    public init(apiKey: String, model: String = "gpt-5-mini") {
        self.apiKey = apiKey
        self.model = model

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    // Uses the existing ChatCompletionMessage type defined in DeepSeekClient.swift
    public func chat(
        messages: [ChatCompletionMessage],
        temperature: Float = 0.5,
        maxTokens: Int = 4000
    ) async throws -> String {
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let requestBody: [String: Any] = [
            "model": model,
            "messages": messages.map { $0.toDictionary() },
            "max_completion_tokens": maxTokens
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIClientError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw OpenAIClientError.apiError(statusCode: httpResponse.statusCode, message: errorMessage)
        }

        let chatResponse = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)

        guard let firstChoice = chatResponse.choices.first,
              let content = firstChoice.message.content else {
            throw OpenAIClientError.emptyResponse
        }

        return content
    }
}

// MARK: - Response Models

private struct OpenAIChatResponse: Codable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [Choice]

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
}

// MARK: - Error Types

public enum OpenAIClientError: LocalizedError {
    case emptyResponse
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "Empty response from OpenAI API"
        case .invalidResponse:
            return "Invalid response from OpenAI API"
        case .apiError(let statusCode, let message):
            return "OpenAI API error (\(statusCode)): \(message)"
        }
    }
}

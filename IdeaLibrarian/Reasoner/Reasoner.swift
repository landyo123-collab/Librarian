import Foundation

public class Reasoner {
    private let deepSeekClient: DeepSeekClient
    private let promptBuilder: PromptBuilder
    private let citationValidator: CitationValidator
    private let contextAssembler: ContextAssembler
    private let config: Configuration

    public init(
        deepSeekClient: DeepSeekClient,
        promptBuilder: PromptBuilder,
        citationValidator: CitationValidator,
        contextAssembler: ContextAssembler,
        config: Configuration
    ) {
        self.deepSeekClient = deepSeekClient
        self.promptBuilder = promptBuilder
        self.citationValidator = citationValidator
        self.contextAssembler = contextAssembler
        self.config = config
    }

    public func reason(
        query: String,
        context: RetrievalContext,
        policy: AssistantPolicy,
        citeRequested: Bool,
        includeNoteInstruction: Bool = false,
        conceptNote: String? = nil
    ) async throws -> ReasoningResult {
        let startTime = Date()

        // Format context for prompt (inject concept note as internal memory if available)
        let contextText = contextAssembler.formatContext(context, conceptNote: conceptNote)

        // Build messages
        let messages = promptBuilder.buildMessages(
            query: query,
            context: contextText,
            policy: policy,
            citeRequested: citeRequested,
            hasSources: !context.results.isEmpty || conceptNote != nil,
            includeNoteInstruction: includeNoteInstruction
        )

        let sourceCount = context.results.count

        if policy == .librarian && sourceCount == 0 {
            throw ReasonerError.insufficientEvidence
        }

        // Call DeepSeek API
        let response = try await deepSeekClient.chat(
            messages: messages,
            temperature: config.temperature,
            maxTokens: config.maxTokens
        )

        // No sources in context — skip citation validation entirely
        if sourceCount == 0 {
            let processingTime = Date().timeIntervalSince(startTime)
            return ReasoningResult(
                response: response,
                ccrScore: 1.0,
                citedSources: [],
                totalSources: 0,
                citationCount: 0,
                processingTime: processingTime,
                attemptCount: 1
            )
        }

        if policy == .chat && !citeRequested {
            let processingTime = Date().timeIntervalSince(startTime)
            return ReasoningResult(
                response: response,
                ccrScore: 1.0,
                citedSources: [],
                totalSources: sourceCount,
                citationCount: 0,
                processingTime: processingTime,
                attemptCount: 1
            )
        }

        if policy == .chat && citeRequested {
            let validation = citationValidator.validate(response: response, sourceCount: sourceCount)
            let processingTime = Date().timeIntervalSince(startTime)
            return ReasoningResult(
                response: response,
                ccrScore: validation.ccr,
                citedSources: validation.citedSources,
                totalSources: validation.totalSources,
                citationCount: validation.citationCount,
                processingTime: processingTime,
                attemptCount: 1
            )
        }

        // Validate citations, retry if CCR is below threshold
        var lastResponse = response
        var lastValidation = citationValidator.validate(response: response, sourceCount: sourceCount)

        if lastValidation.ccr >= config.ccrThreshold {
            let processingTime = Date().timeIntervalSince(startTime)
            return ReasoningResult(
                response: response,
                ccrScore: lastValidation.ccr,
                citedSources: lastValidation.citedSources,
                totalSources: lastValidation.totalSources,
                citationCount: lastValidation.citationCount,
                processingTime: processingTime,
                attemptCount: 1
            )
        }

        // First attempt failed CCR — retry up to maxRetries
        for attempt in 1...config.maxRetries {
            print("CCR below threshold (\(lastValidation.ccr) < \(config.ccrThreshold)). Retrying... (attempt \(attempt)/\(config.maxRetries))")

            let retryResponse = try await deepSeekClient.chat(
                messages: messages,
                temperature: config.temperature,
                maxTokens: config.maxTokens
            )

            let validation = citationValidator.validate(response: retryResponse, sourceCount: sourceCount)
            lastResponse = retryResponse
            lastValidation = validation

            if validation.ccr >= config.ccrThreshold {
                let processingTime = Date().timeIntervalSince(startTime)
                return ReasoningResult(
                    response: retryResponse,
                    ccrScore: validation.ccr,
                    citedSources: validation.citedSources,
                    totalSources: validation.totalSources,
                    citationCount: validation.citationCount,
                    processingTime: processingTime,
                    attemptCount: attempt + 1
                )
            }
        }

        throw ReasonerError.insufficientCitations(
            ccr: lastValidation.ccr,
            threshold: config.ccrThreshold,
            response: lastResponse
        )
    }
}

public struct ReasoningResult {
    public let response: String
    public let ccrScore: Float
    public let citedSources: [Int]
    public let totalSources: Int
    public let citationCount: Int
    public let processingTime: TimeInterval
    public let attemptCount: Int

    public init(
        response: String,
        ccrScore: Float,
        citedSources: [Int] = [],
        totalSources: Int = 0,
        citationCount: Int = 0,
        processingTime: TimeInterval = 0,
        attemptCount: Int = 1
    ) {
        self.response = response
        self.ccrScore = ccrScore
        self.citedSources = citedSources
        self.totalSources = totalSources
        self.citationCount = citationCount
        self.processingTime = processingTime
        self.attemptCount = attemptCount
    }
}

public enum ReasonerError: LocalizedError {
    case insufficientEvidence
    case insufficientCitations(ccr: Float, threshold: Float, response: String)

    public var errorDescription: String? {
        switch self {
        case .insufficientEvidence:
            return "Insufficient evidence: no sources were retrieved for this query."
        case .insufficientCitations(let ccr, let threshold, _):
            return "Insufficient citation coverage: \(String(format: "%.2f", ccr)) < \(String(format: "%.2f", threshold)). The response did not cite enough sources."
        }
    }
}

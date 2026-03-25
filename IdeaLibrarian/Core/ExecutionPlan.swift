import Foundation

/// Central execution authority for query processing
/// Derived from: QueryPolicy, TriggerLexicon, TopicSynthesisDetector, Configuration
public struct ExecutionPlan {
    public enum RetrievalStrategy {
        case none           // Greetings, small talk
        case standard       // Normal retrieval
        case synthesis      // Broad-topic with large candidate pool
    }

    public enum OutputFormat {
        case conversational // Natural chat response
        case synthesis      // THREADS/CONNECTIONS/UNCERTAINTIES/NEXT_STEP/NOTE
        case citation       // With [Source N] citations
    }

    // Core retrieval parameters
    public let strategy: RetrievalStrategy
    public let initialK: Int              // Initial candidates to retrieve
    public let finalK: Int                // Final results after filtering
    public let ccrThreshold: Float        // Citation coverage threshold

    // Memory preferences
    public let preferNotes: Bool          // Boost AtlasNotes over raw chunks
    public let noteBoost: Float           // How much to boost notes (default 1.5)

    // Context building
    public let includeHistory: Bool       // Include chat history
    public let historyTurns: Int          // How many turns to include (default 5)

    // Output control
    public let outputFormat: OutputFormat
    public let shouldDistill: Bool        // Create AtlasNote from response

    // Debug info
    public let intent: String
    public let triggerIntensity: Float
    public let isBroadTopic: Bool

    public init(
        strategy: RetrievalStrategy = .standard,
        initialK: Int = 20,
        finalK: Int = 10,
        ccrThreshold: Float = 0.9,
        preferNotes: Bool = true,
        noteBoost: Float = 1.5,
        includeHistory: Bool = true,
        historyTurns: Int = 5,
        outputFormat: OutputFormat = .conversational,
        shouldDistill: Bool = true,
        intent: String = "general",
        triggerIntensity: Float = 0.0,
        isBroadTopic: Bool = false
    ) {
        self.strategy = strategy
        self.initialK = initialK
        self.finalK = finalK
        self.ccrThreshold = ccrThreshold
        self.preferNotes = preferNotes
        self.noteBoost = noteBoost
        self.includeHistory = includeHistory
        self.historyTurns = historyTurns
        self.outputFormat = outputFormat
        self.shouldDistill = shouldDistill
        self.intent = intent
        self.triggerIntensity = triggerIntensity
        self.isBroadTopic = isBroadTopic
    }
}

/// Builds ExecutionPlan from existing policy modules
public class ExecutionPlanner {
    private let config: Configuration
    private let triggerLexicon: TriggerLexicon
    private let queryPolicy: QueryPolicy
    private let topicDetector: TopicSynthesisDetector

    public init(config: Configuration) {
        self.config = config

        // Initialize trigger lexicon (used by both QueryPolicy and TopicSynthesisDetector)
        self.triggerLexicon = TriggerLexicon(
            jsonPath: config.triggerLexiconPath
        )

        // Initialize canon terms for QueryPolicy
        let canonTerms = CanonTerms(
            jsonPath: config.canonTermsPath
        )

        // Initialize QueryPolicy with trigger lexicon and canon terms
        self.queryPolicy = QueryPolicy(
            triggerLexicon: triggerLexicon,
            canonTerms: canonTerms
        )

        // Initialize TopicSynthesisDetector with trigger lexicon
        self.topicDetector = TopicSynthesisDetector(
            triggerLexicon: triggerLexicon
        )

        print("[ExecutionPlanner] Initialized with \(triggerLexicon.count) triggers, \(canonTerms.count) canon terms")
    }

    public func buildPlan(
        query: String,
        intent: String,
        frameworkDetected: Bool,
        citeRequested: Bool,
        conversationId: String? = nil
    ) -> ExecutionPlan {
        // Detect greeting
        let isGreeting = GreetingDetector.isGreeting(query)

        // Compute trigger intensity
        let triggerIntensity = triggerLexicon.computeIntensity(for: query)

        // Detect broad-topic synthesis candidate
        let isBroadTopic = topicDetector.isBroadTopic(query: query)

        // Get K from QueryPolicy (uses trigger lexicon + canon terms + semantic heuristics)
        let policyK = queryPolicy.decideK(
            for: query,
            defaultK: config.topK,
            maxK: config.maxTopK,
            isGreetingDetected: isGreeting
        )

        // Determine strategy and K values
        let strategy: ExecutionPlan.RetrievalStrategy
        let initialK: Int
        let finalK: Int

        if isGreeting || intent == "smallTalk" {
            strategy = .none
            initialK = 0
            finalK = 0
        } else if isBroadTopic || frameworkDetected {
            strategy = .synthesis
            let desiredFinalK = min(config.maxTopK, max(20, config.topK))
            initialK = max(120, desiredFinalK)  // Large candidate pool for synthesis
            finalK = desiredFinalK              // Filtered final
        } else if policyK >= 10 {
            strategy = .standard
            initialK = policyK
            finalK = policyK
        } else if policyK > 0 {
            strategy = .standard
            initialK = policyK
            finalK = policyK
        } else {
            // PolicyK = 0, but check if intent suggests retrieval
            if intent == "atlasRequested" || intent == "citeRequested" || intent == "deepFromDocs" || intent == "definitional" {
                strategy = .standard
                initialK = max(10, config.topK)
                finalK = config.topK
            } else {
                strategy = .none
                initialK = 0
                finalK = 0
            }
        }

        // Determine output format
        let outputFormat: ExecutionPlan.OutputFormat
        if citeRequested {
            outputFormat = .citation
        } else if isBroadTopic && strategy == .synthesis {
            outputFormat = .synthesis
        } else {
            outputFormat = .conversational
        }

        // Include history if we have a conversation context
        let includeHistory = conversationId != nil

        // Should distill if we're doing retrieval and not in citation mode
        let shouldDistill = strategy != .none && !citeRequested

        // Debug output
        if strategy != .none {
            let matchedTriggers = queryPolicy.getMatchingTriggers(in: query).prefix(3)
            let matchedCanon = queryPolicy.getMatchingCanonTerms(in: query)
            print("[ExecutionPlanner] intensity=\(String(format: "%.1f", triggerIntensity)), policyK=\(policyK), strategy=\(strategy)")
            if !matchedTriggers.isEmpty {
                print("[ExecutionPlanner] triggers: \(matchedTriggers.map { $0.term }.joined(separator: ", "))")
            }
            if !matchedCanon.isEmpty {
                print("[ExecutionPlanner] canon: \(matchedCanon.joined(separator: ", "))")
            }
        }

        return ExecutionPlan(
            strategy: strategy,
            initialK: initialK,
            finalK: finalK,
            ccrThreshold: config.ccrThreshold,
            preferNotes: true,
            noteBoost: config.notePriorityBoost,
            includeHistory: includeHistory,
            historyTurns: 5,
            outputFormat: outputFormat,
            shouldDistill: shouldDistill,
            intent: intent,
            triggerIntensity: triggerIntensity,
            isBroadTopic: isBroadTopic
        )
    }

    /// Extract topic from broad-topic query (for stats and evidence mining)
    public func extractTopic(from query: String) -> String? {
        return topicDetector.extractTopic(from: query)
    }
}

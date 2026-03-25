import Foundation

/// Detects broad-topic queries that should trigger synthesis mode
/// Examples: "what is consciousness", "define agency", "self", "consciousness"
public class TopicSynthesisDetector {
    private let triggerLexicon: TriggerLexicon?

    public init(triggerLexicon: TriggerLexicon? = nil) {
        self.triggerLexicon = triggerLexicon
    }

    /// Classify query as broad-topic synthesis candidate
    public func isBroadTopic(query: String) -> Bool {
        // Pattern 1: "what is X", "define X", "explain X"
        if matchesDefinitionalPattern(query) {
            return true
        }

        // Pattern 2: Short, single-noun queries (potential framework concepts)
        if isSingleNounQuery(query) {
            return true
        }

        // Pattern 3: High trigger intensity
        if let lexicon = triggerLexicon {
            let intensity = lexicon.computeIntensity(for: query)
            if intensity > 50 {  // Medium-high threshold
                return true
            }
        }

        // Pattern 4: Explicit framework/concept keywords
        if hasFrameworkKeywords(query) {
            return true
        }

        return false
    }

    /// Check for definitional patterns: "what is", "define", "explain", "describe"
    private func matchesDefinitionalPattern(_ query: String) -> Bool {
        let lower = query.lowercased()
        let patterns = [
            "what is ",
            "what are ",
            "what was ",
            "what were ",
            "define ",
            "explain ",
            "describe ",
            "tell me about",
            "how does",
            "how do"
        ]

        return patterns.contains { lower.hasPrefix($0) }
    }

    /// Check if query is a single noun/short phrase (e.g., "consciousness", "agency", "identity")
    private func isSingleNounQuery(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Ultra-short (1-4 words, no question mark if possible)
        let words = trimmed.split(separator: " ")
        if words.count > 4 {
            return false
        }

        // If it has a question mark or "is", it's probably a definitional query
        if trimmed.contains("?") {
            return !trimmed.contains("?") || matchesDefinitionalPattern(trimmed)
        }

        // Check if it's a known framework concept
        let conceptKeywords = [
            "consciousness", "agency", "identity", "self", "boundary",
            "coherence", "integration", "emergence", "invariant",
            "framework", "geometry", "field", "space", "control",
            "collapse", "truth", "prediction", "synthesis"
        ]

        return conceptKeywords.contains(trimmed)
    }

    /// Check for explicit synthesis-oriented concepts
    private func hasFrameworkKeywords(_ query: String) -> Bool {
        let lower = query.lowercased()
        let keywords = [
            "consciousness", "agency", "identity", "boundary", "coherence",
            "integration", "invariant", "framework", "knowledge base", "corpus",
            "architecture", "retrieval", "index", "embedding", "synthesis"
        ]

        return keywords.contains { lower.contains($0) }
    }

    /// Extract the key topic/term from a broad-topic query
    /// E.g., "what is consciousness?" → "consciousness"
    public func extractTopic(from query: String) -> String? {
        let lower = query.lowercased()

        let prefixes = [
            "what is ", "what are ", "what was ", "what were ",
            "define ", "explain ", "describe ",
            "tell me about ", "how does ", "how do "
        ]

        for prefix in prefixes {
            if lower.hasPrefix(prefix) {
                var topic = String(lower.dropFirst(prefix.count))
                // Remove punctuation
                topic = topic.trimmingCharacters(in: CharacterSet(charactersIn: "?!.,;:"))
                // Remove articles
                for article in ["a ", "an ", "the "] {
                    if topic.hasPrefix(article) {
                        topic = String(topic.dropFirst(article.count))
                        break
                    }
                }
                return topic.isEmpty ? nil : topic
            }
        }

        // For single-noun queries
        let trimmed = lower.trimmingCharacters(in: CharacterSet(charactersIn: "?!.,;:"))
        let words = trimmed.split(separator: " ")
        if words.count <= 2 {
            return trimmed.isEmpty ? nil : trimmed
        }

        return nil
    }
}

/// Synthesis retrieval strategy configuration
public enum RetrievalStrategy {
    case standard        // Normal BM25 + semantic, small K
    case synthesis       // Large candidate pool, folder weights, diversity quota
    case highPrecision   // Small K, strict relevance
    case exhaustive      // Maximum K, all folders equally weighted
}

/// Result of synthesis detection
public struct SynthesisDetectionResult {
    public let isSynthesisCandidate: Bool
    public let strategy: RetrievalStrategy
    public let topic: String?
    public let confidence: Float

    public init(isSynthesisCandidate: Bool, strategy: RetrievalStrategy, topic: String?, confidence: Float) {
        self.isSynthesisCandidate = isSynthesisCandidate
        self.strategy = strategy
        self.topic = topic
        self.confidence = confidence
    }
}

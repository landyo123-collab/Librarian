import Foundation

/// Phase 10: QueryPolicy - Hybrid decision logic for retrieval vs. conversational chat
///
/// Implements a two-layer decision system:
/// - Layer A: Trigger-based intensity (from TriggerLexicon)
/// - Layer B: Semantic intent classification (greeting, technical, explicit request)
///
/// Also enforces a critical terms list (canon terms) that always trigger retrieval.
public class QueryPolicy {
    private let triggerLexicon: TriggerLexicon
    private let canonTerms: CanonTerms

    public init(triggerLexicon: TriggerLexicon, canonTerms: CanonTerms) {
        self.triggerLexicon = triggerLexicon
        self.canonTerms = canonTerms
    }

    /// Decide retrieval depth (K) based on query
    /// - Parameters:
    ///   - query: User's query string
    ///   - defaultK: Default K from config
    ///   - maxK: Maximum K allowed
    ///   - isGreetingDetected: If true, forces K=0
    /// - Returns: Recommended K value (0 = no retrieval)
    public func decideK(
        for query: String,
        defaultK: Int,
        maxK: Int,
        isGreetingDetected: Bool
    ) -> Int {
        // Layer 0: Greeting detection (highest priority)
        if isGreetingDetected {
            return 0
        }

        // Layer 1: Check critical canon terms (always trigger retrieval)
        if canonTerms.containsAny(in: query) {
            return min(maxK, max(10, defaultK))
        }

        // Layer 1.5: Code query detection — Python or Swift (force higher K)
        if hasCodeIntent(query) {
            return min(maxK, max(10, defaultK))
        }

        // Layer 2: Compute trigger-based intensity
        let intensity = triggerLexicon.computeIntensity(for: query)
        let kFromIntensity = triggerLexicon.mapIntensityToK(intensity: intensity, maxK: maxK)

        // Layer 3: Semantic heuristics for technical intent
        let hasSemanticHint = hasInternalTechnicalIntent(query)

        if kFromIntensity > 0 {
            return kFromIntensity
        } else if hasSemanticHint {
            // If semantic analysis suggests indexed content is likely relevant, retrieve moderately
            return min(maxK, max(3, defaultK))
        } else {
            // Default: no retrieval for generic queries
            return 0
        }
    }

    /// Check if query is asking about source code (Python or Swift) from project files.
    /// Forces K≥10 so multiple relevant functions/types are retrieved.
    private func hasCodeIntent(_ query: String) -> Bool {
        let lower = query.lowercased()

        // Explicit language / code keywords (Python + Swift)
        let codeKeywords = [
            // Language names and file extensions
            "python", ".py", "swift", ".swift",
            // Universal code concepts
            "source code", "in the project", "in project",
            "function", "method", "class def", "def ",
            "import statement", "implementation", "algorithm", "script", "module",
            // Swift-specific
            "struct", "protocol", "extension", "viewmodel", "swiftui", "uikit",
            "guard let", "if let", "actor ", "async ", "await "
        ]
        for keyword in codeKeywords {
            if lower.contains(keyword) {
                return true
            }
        }

        // Code query action patterns (regex) — language-agnostic phrasing
        let codePatterns = [
            "\\bdef\\b",                                      // Python def keyword
            "\\bfunc\\b",                                     // Swift func keyword
            "\\bstruct\\b",                                   // Swift struct
            "\\bclass\\b.*\\bdo\\b",
            "show me.*(function|method|class|struct|code)",
            "where is.*(defined|implemented|declared)",
            "how does.*(function|method|class|struct|work)",
            "what does.*(function|method|class|struct)",
            "find.*(function|class|struct|method).*(project|file)",
            "code for",
            "source (of|for)"
        ]
        for pattern in codePatterns {
            if lower.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }

        return false
    }

    /// Check if query suggests technical content likely to exist in local files
    private func hasInternalTechnicalIntent(_ query: String) -> Bool {
        let patterns = [
            // Math symbols
            "Ω", "κ", "Π", "Φ", "∞", "∫", "∇", "∂",
            // General technical topics
            "embedding", "retrieval", "index", "database", "schema",
            "swift", "python", "api", "token", "chunk",
            // Technical word combinations
            "data.*flow", "query.*plan", "search.*ranking", "prompt.*context"
        ]

        for pattern in patterns {
            if query.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }

        // Heuristic: multiword technical query (3+ words with no small talk markers)
        let wordCount = query.split(separator: " ").count
        if wordCount >= 3 {
            let smallTalkMarkers = ["is", "a", "the", "and", "or", "what", "how", "why"]
            let words = query.lowercased().split(separator: " ")
            let technicalWords = words.filter { !smallTalkMarkers.contains(String($0)) }
            if technicalWords.count >= 2 {
                return true
            }
        }

        return false
    }

    /// Get matching triggers for display/debugging
    public func getMatchingTriggers(in query: String) -> [(term: String, score: Float)] {
        return triggerLexicon.findMatches(in: query)
    }

    /// Get matching canon terms for display/debugging
    public func getMatchingCanonTerms(in query: String) -> [String] {
        return canonTerms.findMatches(in: query)
    }
}

/// Phase 10: CanonTerms - Optional high-priority terms that force retrieval
///
/// These terms can be loaded from JSON and tuned per dataset.
public class CanonTerms {
    private var terms: Set<String> = []

    public init(jsonPath: String = "") {
        if jsonPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            loadHardcodedFallback()
            return
        }

        do {
            try load(from: jsonPath)
        } catch {
            print("[CanonTerms] Failed to load from \(jsonPath): \(error)")
            // Load hardcoded fallback
            loadHardcodedFallback()
        }
    }

    /// Load canon terms from JSON file
    private func load(from path: String) throws {
        let fileURL = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: fileURL)

        let decoder = JSONDecoder()
        let structure = try decoder.decode(CanonTermsStructure.self, from: data)

        terms = Set(structure.terms.map { $0.lowercased() })
        print("[CanonTerms] Loaded \(terms.count) canon terms")
    }

    /// Fallback terms (dataset-agnostic)
    private func loadHardcodedFallback() {
        let hardcoded = [
            "swift",
            "python",
            "index",
            "embedding",
            "retrieval",
            "database",
            "schema"
        ]

        terms = Set(hardcoded.map { $0.lowercased() })
        print("[CanonTerms] Loaded \(terms.count) hardcoded canon terms")
    }

    /// Check if query contains any canon term
    public func containsAny(in query: String) -> Bool {
        let queryLower = query.lowercased()
        return terms.contains { term in
            queryLower.contains(term)
        }
    }

    /// Find which canon terms appear in query
    public func findMatches(in query: String) -> [String] {
        let queryLower = query.lowercased()
        return terms.filter { term in
            queryLower.contains(term)
        }.sorted()
    }

    /// Return count of loaded terms
    public var count: Int {
        return terms.count
    }

    // MARK: - Internal Structure

    private struct CanonTermsStructure: Codable {
        let terms: [String]
        let description: String?
    }
}

// MARK: - Greeting Detector

/// Simple greeting detection utility
public struct GreetingDetector {
    private static let greetingPatterns = [
        // Simple greetings
        "^hi$", "^hello$", "^hey$", "^sup$", "^yo$",
        // Gratitude
        "^thanks$", "^thank you$", "^thx$", "^ty$",
        // How are you
        "^how are you", "^how are you\\?", "^how's it going",
        // Courtesy
        "^please$", "^ok$", "^okay$",
        // Casual
        "^lol$", "^rofl$", "^haha$"
    ]

    /// Detect if query is a greeting/small talk
    public static func isGreeting(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Ultra-short queries (< 12 chars) are usually small talk
        if trimmed.count < 12 {
            // Check against patterns
            for pattern in greetingPatterns {
                if trimmed.range(of: pattern, options: .regularExpression) != nil {
                    return true
                }
            }
        }

        // Check for standalone greeting words in very short queries
        let words = trimmed.split(separator: " ")
        if words.count <= 2 {
            let greetingWords = ["hi", "hello", "hey", "thanks", "thank", "ok", "okay"]
            return words.allSatisfy { greetingWords.contains(String($0)) }
        }

        return false
    }
}

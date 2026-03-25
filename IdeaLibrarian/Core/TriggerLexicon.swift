import Foundation

/// Phase 10: TriggerLexicon - Loads and computes query intensity from trigger terms.
///
/// Loads optional high-signal triggers from JSON and computes query intensity
/// by matching trigger terms in user queries. Intensity is then mapped to retrieval depth (K).
public class TriggerLexicon {
    private var triggers: [String: TriggerTerm] = [:]

    public struct TriggerTerm: Codable {
        public let term: String
        public let type: String  // unigram, bigram, phrase, symbol
        public let score: Float
        public let count_total: Int
        public let count_by_folder: [String: Int]
    }

    public init(jsonPath: String = "") {
        guard !jsonPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            loadDefaultTriggers()
            return
        }
        do {
            try load(from: jsonPath)
            if triggers.isEmpty {
                loadDefaultTriggers()
            }
        } catch {
            print("[TriggerLexicon] Failed to load triggers from \(jsonPath): \(error)")
            loadDefaultTriggers()
        }
    }

    /// Load triggers from JSON file
    private func load(from path: String) throws {
        let fileURL = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: fileURL)

        let decoder = JSONDecoder()
        let structure = try decoder.decode(TriggerStructure.self, from: data)

        // Index triggers by term for fast lookup
        for trigger in structure.triggers {
            triggers[trigger.term.lowercased()] = trigger
        }

        print("[TriggerLexicon] Loaded \(triggers.count) triggers from \(path)")
    }

    private func loadDefaultTriggers() {
        let defaults: [(String, String, Float)] = [
            ("define", "unigram", 10),
            ("explain", "unigram", 10),
            ("summarize", "unigram", 9),
            ("architecture", "unigram", 12),
            ("implementation", "unigram", 12),
            ("retrieval", "unigram", 13),
            ("embedding", "unigram", 13),
            ("citation", "unigram", 11),
            ("evidence", "unigram", 11),
            ("swift", "unigram", 10),
            ("python", "unigram", 10),
            ("database", "unigram", 12),
            ("sqlite", "unigram", 12),
            ("index", "unigram", 11),
            ("vector search", "phrase", 14),
            ("full text search", "phrase", 14)
        ]

        triggers = Dictionary(
            uniqueKeysWithValues: defaults.map { term, type, score in
                (
                    term.lowercased(),
                    TriggerTerm(
                        term: term.lowercased(),
                        type: type,
                        score: score,
                        count_total: 1,
                        count_by_folder: ["general": 1]
                    )
                )
            }
        )
        print("[TriggerLexicon] Loaded \(triggers.count) built-in default triggers")
    }

    /// Compute query intensity by summing scores of matched triggers
    /// - Parameter query: The user's query string
    /// - Returns: Total intensity score (0 or higher)
    public func computeIntensity(for query: String) -> Float {
        guard !triggers.isEmpty else { return 0.0 }

        var totalScore: Float = 0.0
        let queryLower = query.lowercased()

        // Match both exact terms and substrings
        for (term, trigger) in triggers {
            // Exact word match (preferred)
            if queryLower.contains(" \(term) ") || queryLower.hasPrefix("\(term) ") ||
               queryLower.hasSuffix(" \(term)") || queryLower == term {
                totalScore += trigger.score
            }
            // Substring match (for phrases and longer terms)
            else if queryLower.contains(term) && term.count >= 3 {
                totalScore += trigger.score * 0.5  // Half weight for substring match
            }
        }

        return totalScore
    }

    /// Map intensity to retrieval depth (K)
    /// - Parameter intensity: Query intensity score
    /// - Parameter maxK: Maximum K value (usually config.maxTopK)
    /// - Returns: Recommended K (number of documents to retrieve)
    public func mapIntensityToK(intensity: Float, maxK: Int = 15) -> Int {
        if intensity < 10 {
            return 0   // No retrieval
        } else if intensity < 30 {
            return min(3, maxK)   // Light retrieval
        } else if intensity < 60 {
            return min(10, maxK)  // Standard retrieval
        } else {
            return min(15, maxK)  // Full retrieval
        }
    }

    /// Check if query contains any known critical framework terms
    /// - Parameter query: The user's query string
    /// - Returns: List of matched triggers with their scores
    public func findMatches(in query: String) -> [(term: String, score: Float)] {
        var matches: [(String, Float)] = []
        let queryLower = query.lowercased()

        for (term, trigger) in triggers {
            if queryLower.contains(" \(term) ") || queryLower.hasPrefix("\(term) ") ||
               queryLower.hasSuffix(" \(term)") || queryLower == term {
                matches.append((term, trigger.score))
            }
        }

        return matches.sorted { $0.1 > $1.1 }
    }

    /// Get the score for a specific term
    public func score(for term: String) -> Float? {
        return triggers[term.lowercased()]?.score
    }

    /// Return total number of loaded triggers
    public var count: Int {
        return triggers.count
    }

    // MARK: - Internal Structure

    private struct TriggerStructure: Codable {
        let metadata: [String: AnyCodable]?
        let triggers: [TriggerTerm]
    }
}

/// Helper for decoding JSON with mixed types
private enum AnyCodable: Codable {
    case string(String)
    case number(Float)
    case bool(Bool)
    case array([AnyCodable])
    case dict([String: AnyCodable])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Float.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([AnyCodable].self) {
            self = .array(array)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self = .dict(dict)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode AnyCodable")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let bool):
            try container.encode(bool)
        case .number(let number):
            try container.encode(number)
        case .string(let string):
            try container.encode(string)
        case .array(let array):
            try container.encode(array)
        case .dict(let dict):
            try container.encode(dict)
        }
    }
}

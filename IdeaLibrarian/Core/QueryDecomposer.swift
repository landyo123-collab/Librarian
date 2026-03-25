import Foundation

public struct QueryDecomposer {
    private let minSubqueryLength: Int

    public init(minSubqueryLength: Int = 12) {
        self.minSubqueryLength = minSubqueryLength
    }

    public func decompose(query: String, maxSubqueries: Int) -> [String] {
        let normalized = query
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized.isEmpty { return [] }

        var working = normalized
        let connectorPatterns = [
            "(?i)\\s+and\\s+",
            "(?i)\\s+then\\s+",
            "(?i)\\s+vs\\s+",
            "(?i)\\s+versus\\s+",
            "(?i)\\s+compared\\s+to\\s+",
            "(?i)\\s+relative\\s+to\\s+"
        ]

        for pattern in connectorPatterns {
            working = working.replacingOccurrences(of: pattern, with: " | ", options: .regularExpression)
        }

        let separators = [";", "|", "\n", ","]
        for sep in separators {
            working = working.replacingOccurrences(of: sep, with: " | ")
        }

        let rawParts = working.components(separatedBy: "|")
        let trimmedParts = rawParts.map { trimPunctuation($0) }

        var results: [String] = []
        var seen = Set<String>()

        for part in trimmedParts {
            let candidate = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.isEmpty { continue }

            let wordCount = candidate.split(separator: " ").count
            let longEnough = candidate.count >= minSubqueryLength
            let valid = (wordCount >= 2 && candidate.count >= 4) || longEnough
            if !valid { continue }

            let key = candidate.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            results.append(candidate)

            if results.count >= maxSubqueries { break }
        }

        return results
    }

    private func trimPunctuation(_ text: String) -> String {
        let punctuation = CharacterSet(charactersIn: ".,;:!?()[]{}\"'`“”‘’")
        return text.trimmingCharacters(in: punctuation)
    }

#if DEBUG
    public static func demo() {
        let decomposer = QueryDecomposer(minSubqueryLength: 12)
        let samples = [
            "Compare LLM retrieval and RAG, then outline latency tradeoffs",
            "saved notes vs documents; how do boosts affect ranking?",
            "Embedding cost, indexing time, and cache strategy",
            "Summarize CCR and refusal logic"
        ]

        for sample in samples {
            let parts = decomposer.decompose(query: sample, maxSubqueries: 4)
            print("Decompose demo: \"\(sample)\"")
            for part in parts {
                print("- \(part)")
            }
        }
    }
#endif
}

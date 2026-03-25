import Foundation

public class CitationValidator {
    public init() {}

    public func validate(response: String, sourceCount: Int) -> CitationValidationResult {
        let citations = extractCitations(from: response)
        let uniqueSources = Set(citations)

        // Calculate Citation Coverage Rate (CCR)
        let ccr = sourceCount > 0 ? Float(uniqueSources.count) / Float(sourceCount) : 1.0

        return CitationValidationResult(
            ccr: ccr,
            citedSources: Array(uniqueSources).sorted(),
            totalSources: sourceCount,
            citationCount: citations.count
        )
    }

    private func extractCitations(from text: String) -> [Int] {
        // Regex to match [Source N] or [Source N, M, ...]
        let pattern = #"\[Source\s+([\d,\s]+)\]"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }

        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)

        var citations: [Int] = []

        for match in matches {
            if match.numberOfRanges > 1 {
                let numbersRange = match.range(at: 1)
                if let swiftRange = Range(numbersRange, in: text) {
                    let numbersString = String(text[swiftRange])
                    let numbers = numbersString
                        .components(separatedBy: ",")
                        .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    citations.append(contentsOf: numbers)
                }
            }
        }

        return citations
    }
}

public struct CitationValidationResult {
    public let ccr: Float
    public let citedSources: [Int]
    public let totalSources: Int
    public let citationCount: Int

    public var isValid: Bool {
        return ccr >= 0.9  // 90% threshold
    }

    public var description: String {
        return "CCR: \(String(format: "%.2f", ccr)) (\(citedSources.count)/\(totalSources) sources cited, \(citationCount) total citations)"
    }
}

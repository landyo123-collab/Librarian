import Foundation

public class DistillationEngine {
    private let maxSummaryChars: Int
    private let maxBullets: Int
    private let maxParagraphs: Int
    private let maxConcepts: Int
    private let notePriorityBoost: Float

    public init(
        notePriorityBoost: Float,
        maxSummaryChars: Int = 1800,
        maxBullets: Int = 8,
        maxParagraphs: Int = 8,
        maxConcepts: Int = 12
    ) {
        self.notePriorityBoost = notePriorityBoost
        self.maxSummaryChars = maxSummaryChars
        self.maxBullets = maxBullets
        self.maxParagraphs = maxParagraphs
        self.maxConcepts = maxConcepts
    }

    public func distill(
        query: String,
        answer: String,
        sources: [RetrievalResult],
        now: Date = Date()
    ) -> AtlasNote {
        let summary = buildSummary(from: answer)
        let concepts = extractConcepts(summary: summary, answer: answer)
        let sourceChunkIds = normalizeSourceChunkIds(from: sources)

        // TODO: Consider LLM-based distillation for higher fidelity summaries.
        return AtlasNote(
            id: UUID().uuidString,
            query: query,
            summary: summary,
            keyConcepts: concepts,
            sourceChunkIds: sourceChunkIds,
            createdAt: now,
            retrievalBoost: notePriorityBoost
        )
    }

    private func buildSummary(from answer: String) -> String {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Summary unavailable."
        }

        let bullets = extractBullets(from: trimmed)
        if bullets.count >= 2 {
            let selected = Array(bullets.prefix(maxBullets))
            let joined = selected.joined(separator: "\n")
            return truncate(joined, maxChars: maxSummaryChars)
        }

        let paragraphs = extractParagraphs(from: trimmed)
        var collected: [String] = []
        var totalChars = 0
        for paragraph in paragraphs.prefix(maxParagraphs) {
            if totalChars + paragraph.count > maxSummaryChars {
                break
            }
            collected.append(paragraph)
            totalChars += paragraph.count
        }

        if collected.isEmpty {
            return truncate(trimmed, maxChars: maxSummaryChars)
        }

        let joined = collected.joined(separator: "\n\n")
        return truncate(joined, maxChars: maxSummaryChars)
    }

    private func extractBullets(from text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var bullets: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || isNumberedBullet(trimmed) {
                bullets.append(trimmed)
            }
        }
        return bullets
    }

    private func isNumberedBullet(_ line: String) -> Bool {
        let pattern = "^[0-9]+\\.\\s+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(location: 0, length: line.utf16.count)
        return regex.firstMatch(in: line, range: range) != nil
    }

    private func extractParagraphs(from text: String) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n")
        return paragraphs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func truncate(_ text: String, maxChars: Int) -> String {
        if text.count <= maxChars { return text }
        let index = text.index(text.startIndex, offsetBy: maxChars)
        var truncated = String(text[..<index])
        if let lastSpace = truncated.lastIndex(of: " ") {
            truncated = String(truncated[..<lastSpace])
        }
        return truncated + "..."
    }

    private func extractConcepts(summary: String, answer: String) -> [String] {
        let combined = summary + "\n\n" + answer
        var concepts: [String] = []

        let backtickPattern = "`([^`]{2,60})`"
        if let regex = try? NSRegularExpression(pattern: backtickPattern) {
            let range = NSRange(location: 0, length: combined.utf16.count)
            regex.enumerateMatches(in: combined, range: range) { match, _, _ in
                guard let match = match, match.numberOfRanges > 1 else { return }
                if let range = Range(match.range(at: 1), in: combined) {
                    let term = String(combined[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !term.isEmpty {
                        concepts.append(term)
                    }
                }
            }
        }

        let capitalizedPattern = "\\b([A-Z][A-Za-z0-9]+(?:\\s+[A-Z][A-Za-z0-9]+){0,2})\\b"
        if let regex = try? NSRegularExpression(pattern: capitalizedPattern) {
            let range = NSRange(location: 0, length: combined.utf16.count)
            regex.enumerateMatches(in: combined, range: range) { match, _, _ in
                guard let match = match else { return }
                if let range = Range(match.range(at: 1), in: combined) {
                    let term = String(combined[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if isValidConcept(term) {
                        concepts.append(term)
                    }
                }
            }
        }

        return uniqueOrdered(concepts).prefix(maxConcepts).map { $0 }
    }

    private func isValidConcept(_ term: String) -> Bool {
        if term.count < 3 { return false }
        let stopwords = [
            "The", "And", "But", "For", "With", "This", "That", "These", "Those",
            "A", "An", "In", "On", "At", "By", "To", "From", "As", "Or", "If",
            "Then", "When", "While", "After", "Before", "Because", "However"
        ]
        return !stopwords.contains(term)
    }

    private func uniqueOrdered(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            if !seen.contains(value) {
                seen.insert(value)
                result.append(value)
            }
        }
        return result
    }

    private func normalizeSourceChunkIds(from sources: [RetrievalResult]) -> [String] {
        let ids = sources.map { $0.chunk.id }
        return Array(Set(ids)).sorted()
    }
}

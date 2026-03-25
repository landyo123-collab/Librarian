import Foundation

/// Extracts definition-bearing evidence snippets from retrieval candidates
/// Filters out question-only content and prioritizes declarative statements
public class EvidenceMiner {
    public struct EvidenceSnippet {
        public let text: String
        public let documentId: String
        public let folder: String
        public let sourceChunkId: String?
        public let confidence: Float  // How likely this is a definition/explanation

        public init(text: String, documentId: String, folder: String, sourceChunkId: String?, confidence: Float) {
            self.text = text
            self.documentId = documentId
            self.folder = folder
            self.sourceChunkId = sourceChunkId
            self.confidence = confidence
        }
    }

    public init() {}

    /// Mine evidence from retrieval results
    /// - Parameters:
    ///   - results: RetrievalResult objects to mine
    ///   - topic: The topic being searched (for context)
    ///   - maxSnippets: Maximum number of snippets to extract (default 30)
    /// - Returns: Array of EvidenceSnippet sorted by confidence
    public func mineEvidence(
        from results: [RetrievalResult],
        topic: String,
        maxSnippets: Int = 30
    ) -> [EvidenceSnippet] {
        var snippets: [EvidenceSnippet] = []

        for result in results {
            // Filter out low-content question-only chunks
            if isQuestionOnly(result.chunk.content) && result.chunk.tokenCount < 50 {
                continue
            }

            // Extract declarative sentences
            let sentences = extractDeclarativeSentences(
                result.chunk.content,
                topic: topic
            )

            for sentence in sentences {
                let confidence = calculateConfidence(
                    sentence: sentence,
                    topic: topic,
                    chunkType: result.chunk.contentType
                )

                let folder = extractFolder(from: result.document.sourcePath) ?? "root"

                let snippet = EvidenceSnippet(
                    text: sentence,
                    documentId: result.document.id,
                    folder: folder,
                    sourceChunkId: result.chunk.id,
                    confidence: confidence
                )

                snippets.append(snippet)

                if snippets.count >= maxSnippets {
                    break
                }
            }

            if snippets.count >= maxSnippets {
                break
            }
        }

        // Sort by confidence and return
        return snippets
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxSnippets)
            .map { $0 }
    }

    /// Check if chunk is question-only (no declarative statements)
    private func isQuestionOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if ends with ? and contains no declarative patterns
        if trimmed.hasSuffix("?") && trimmed.split(separator: "\n").count < 3 {
            return true
        }

        // Check if mostly questions
        let lines = trimmed.split(separator: "\n")
        let questionLines = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasSuffix("?") }

        return questionLines.count > lines.count / 2 && lines.count > 2
    }

    /// Extract declarative sentences (1-3 sentences with substantive content)
    private func extractDeclarativeSentences(_ text: String, topic: String) -> [String] {
        var sentences: [String] = []

        let declarativePatterns = [
            "is ", "are ", "was ", "were ",
            "means ", "means: ",
            "defined as ", "definition: ",
            "therefore ", "thus ",
            "we claim ", "claim: ",
            "invariant ", "property: ",
            "implies ", "follows ",
            "represents ", "denotes "
        ]

        // Split into sentences
        let sentenceEndings = CharacterSet(charactersIn: ".!?\n")
        let rawSentences = text.components(separatedBy: sentenceEndings)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count > 10 }

        // Build multi-sentence snippets (1-3 sentences)
        for i in 0..<rawSentences.count {
            // Single sentence
            let sentence1 = rawSentences[i]
            if isDeclarative(sentence1, patterns: declarativePatterns) {
                sentences.append(sentence1)
            }

            // Two sentences
            if i + 1 < rawSentences.count {
                let sentence2 = rawSentences[i + 1]
                let combined = sentence1 + ". " + sentence2
                if combined.count < 200 && isDeclarative(combined, patterns: declarativePatterns) {
                    sentences.append(combined)
                }
            }

            // Three sentences
            if i + 2 < rawSentences.count {
                let sentence2 = rawSentences[i + 1]
                let sentence3 = rawSentences[i + 2]
                let combined = sentence1 + ". " + sentence2 + ". " + sentence3
                if combined.count < 300 && isDeclarative(combined, patterns: declarativePatterns) {
                    sentences.append(combined)
                }
            }
        }

        return Array(sentences.prefix(10))
    }

    /// Check if text contains declarative patterns
    private func isDeclarative(_ text: String, patterns: [String]) -> Bool {
        let lower = text.lowercased()
        return patterns.contains { lower.contains($0) }
    }

    /// Calculate confidence that this is a good definition/explanation
    private func calculateConfidence(
        sentence: String,
        topic: String,
        chunkType: ContentType
    ) -> Float {
        var confidence: Float = 0.5

        // Boost for chunk type (stage1/stage2 are analytical)
        switch chunkType {
        case .stage1, .stage2:
            confidence += 0.2
        case .conclusion:
            confidence += 0.15
        case .question, .nextQuestion:
            confidence -= 0.3
        default:
            confidence += 0.1
        }

        // Boost for topic mention
        if sentence.lowercased().contains(topic.lowercased()) {
            confidence += 0.15
        }

        // Boost for explicit definition patterns
        let definitionPatterns = ["means", "defined as", "is ", "represents", "denotes", "property"]
        if definitionPatterns.contains(where: { sentence.lowercased().contains($0) }) {
            confidence += 0.2
        }

        // Penalty for very short sentences
        if sentence.split(separator: " ").count < 3 {
            confidence -= 0.1
        }

        return min(max(confidence, 0.0), 1.0)
    }

    /// Extract folder from document path
    private func extractFolder(from path: String) -> String? {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        if components.count >= 2 {
            return components[components.count - 2]
        }
        return nil
    }

    /// Format evidence snippets as a block for the prompt
    public static func formatEvidenceBlock(_ snippets: [EvidenceSnippet]) -> String {
        guard !snippets.isEmpty else { return "" }

        var block = "=== EVIDENCE FROM LIBRARIAN ===\n"

        // Group by confidence level
        let highConfidence = snippets.filter { $0.confidence >= 0.7 }
        let mediumConfidence = snippets.filter { $0.confidence >= 0.5 && $0.confidence < 0.7 }

        if !highConfidence.isEmpty {
            block += "\nHigh-confidence explanations:\n"
            for (idx, snippet) in highConfidence.prefix(5).enumerated() {
                block += "\(idx + 1). (\(snippet.folder)) \(snippet.text)\n"
            }
        }

        if !mediumConfidence.isEmpty && highConfidence.count < 5 {
            block += "\nAdditional context:\n"
            for (idx, snippet) in mediumConfidence.prefix(5 - highConfidence.count).enumerated() {
                block += "\(idx + 1). (\(snippet.folder)) \(snippet.text)\n"
            }
        }

        block += "\n"
        return block
    }
}

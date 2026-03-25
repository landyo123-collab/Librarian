import Foundation

public struct ChunkedText {
    public let text: String
    public let tokenCount: Int

    public init(text: String, tokenCount: Int) {
        self.text = text
        self.tokenCount = tokenCount
    }
}

public class ChunkingStrategy {
    private let maxTokens: Int

    public init(maxTokens: Int = 512) {
        self.maxTokens = maxTokens
    }

    public func chunk(text: String, contentType: ContentType) -> [ChunkedText] {
        let estimatedTokens = estimateTokens(text)

        // If text is already under limit, return as single chunk
        if estimatedTokens <= maxTokens {
            return [ChunkedText(text: text, tokenCount: estimatedTokens)]
        }

        // Split on paragraph boundaries
        let paragraphs = text.components(separatedBy: "\n\n")
        var chunks: [ChunkedText] = []
        var currentChunk = ""
        var currentTokens = 0

        for paragraph in paragraphs {
            let paragraphTokens = estimateTokens(paragraph)

            // If a single paragraph exceeds maxTokens, split it further
            if paragraphTokens > maxTokens {
                // Save current chunk if not empty
                if !currentChunk.isEmpty {
                    chunks.append(ChunkedText(text: currentChunk.trimmingCharacters(in: .whitespacesAndNewlines), tokenCount: currentTokens))
                    currentChunk = ""
                    currentTokens = 0
                }

                // Split large paragraph on sentences
                let sentences = splitIntoSentences(paragraph)
                var sentenceBuffer = ""
                var sentenceTokens = 0

                for sentence in sentences {
                    let sentTokens = estimateTokens(sentence)

                    if sentenceTokens + sentenceTokens > maxTokens && !sentenceBuffer.isEmpty {
                        chunks.append(ChunkedText(text: sentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines), tokenCount: sentenceTokens))
                        sentenceBuffer = sentence
                        sentenceTokens = sentTokens
                    } else {
                        sentenceBuffer += sentence
                        sentenceTokens += sentTokens
                    }
                }

                if !sentenceBuffer.isEmpty {
                    chunks.append(ChunkedText(text: sentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines), tokenCount: sentenceTokens))
                }
            } else {
                // Check if adding this paragraph would exceed limit
                if currentTokens + paragraphTokens > maxTokens && !currentChunk.isEmpty {
                    // Save current chunk and start new one
                    chunks.append(ChunkedText(text: currentChunk.trimmingCharacters(in: .whitespacesAndNewlines), tokenCount: currentTokens))
                    currentChunk = paragraph + "\n\n"
                    currentTokens = paragraphTokens
                } else {
                    // Add paragraph to current chunk
                    currentChunk += paragraph + "\n\n"
                    currentTokens += paragraphTokens
                }
            }
        }

        // Add final chunk if not empty
        if !currentChunk.isEmpty {
            chunks.append(ChunkedText(text: currentChunk.trimmingCharacters(in: .whitespacesAndNewlines), tokenCount: currentTokens))
        }

        return chunks.isEmpty ? [ChunkedText(text: text, tokenCount: estimatedTokens)] : chunks
    }

    public func estimateTokens(_ text: String) -> Int {
        // Simple heuristic: ~4 characters per token on average
        // This is an approximation; real tokenization would use tiktoken
        return max(1, text.count / 4)
    }

    private func splitIntoSentences(_ text: String) -> [String] {
        // Simple sentence splitting on common terminators
        let pattern = "([.!?]+\\s+|\\n)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [text]
        }

        var sentences: [String] = []
        var lastIndex = text.startIndex
        let range = NSRange(text.startIndex..., in: text)

        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match, let range = Range(match.range, in: text) else { return }
            let sentence = String(text[lastIndex..<range.upperBound])
            if !sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sentences.append(sentence)
            }
            lastIndex = range.upperBound
        }

        // Add remaining text
        if lastIndex < text.endIndex {
            let remaining = String(text[lastIndex...])
            if !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sentences.append(remaining)
            }
        }

        return sentences.isEmpty ? [text] : sentences
    }
}

import Foundation

public struct JSONEpisode: Codable {
    public let id: String
    public let worldId: String?
    public let evolutionRunId: String?
    public let question: String
    public let stage1Markdown: String
    public let stage2Markdown: String
    public let conclusion: String
    public let contradictions: String?
    public let nextQuestion: String?
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case worldId = "world_id"
        case evolutionRunId = "evolution_run_id"
        case question
        case stage1Markdown = "stage1_markdown"
        case stage2Markdown = "stage2_markdown"
        case conclusion
        case contradictions
        case nextQuestion = "next_question"
        case createdAt = "created_at"
    }
}

public class JSONEpisodeParser {
    private let chunkingStrategy: ChunkingStrategy

    public init(chunkingStrategy: ChunkingStrategy) {
        self.chunkingStrategy = chunkingStrategy
    }

    public func parse(fileURL: URL) throws -> (document: Document, chunks: [Chunk]) {
        let jsonText = try loadJSONText(url: fileURL)
        guard let jsonData = jsonText.data(using: .utf8) else {
            throw CorruptEpisodeFile.invalidUTF8
        }

        let episode: JSONEpisode
        do {
            episode = try JSONDecoder().decode(JSONEpisode.self, from: jsonData)
        } catch {
            if let decodingError = error as? DecodingError {
                throw decodingError
            }
            throw CorruptEpisodeFile.decodeFailed(error.localizedDescription)
        }

        // Create document
        let createdAt: Date
        if let createdAtStr = episode.createdAt {
            createdAt = ISO8601DateFormatter().date(from: createdAtStr) ?? Date()
        } else {
            // Fallback to file modification date
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            createdAt = attributes[.modificationDate] as? Date ?? Date()
        }

        let document = Document(
            id: episode.id,
            sourceType: .jsonEpisode,
            sourcePath: fileURL.path,
            worldId: episode.worldId,
            evolutionRunId: episode.evolutionRunId,
            createdAt: createdAt,
            indexedAt: Date(),
            metadata: [
                "has_contradictions": episode.contradictions != nil ? "true" : "false",
                "has_next_question": episode.nextQuestion != nil ? "true" : "false"
            ]
        )

        // Create chunks
        var chunks: [Chunk] = []
        var chunkIndex = 0

        // Chunk 0: Question (always whole)
        chunks.append(Chunk(
            documentId: document.id,
            chunkIndex: chunkIndex,
            contentType: .question,
            content: episode.question,
            tokenCount: chunkingStrategy.estimateTokens(episode.question)
        ))
        chunkIndex += 1

        // Chunk stage1_markdown
        let stage1Chunks = chunkingStrategy.chunk(
            text: episode.stage1Markdown,
            contentType: .stage1
        )
        for stage1Chunk in stage1Chunks {
            chunks.append(Chunk(
                documentId: document.id,
                chunkIndex: chunkIndex,
                contentType: .stage1,
                content: stage1Chunk.text,
                tokenCount: stage1Chunk.tokenCount
            ))
            chunkIndex += 1
        }

        // Chunk stage2_markdown
        let stage2Chunks = chunkingStrategy.chunk(
            text: episode.stage2Markdown,
            contentType: .stage2
        )
        for stage2Chunk in stage2Chunks {
            chunks.append(Chunk(
                documentId: document.id,
                chunkIndex: chunkIndex,
                contentType: .stage2,
                content: stage2Chunk.text,
                tokenCount: stage2Chunk.tokenCount
            ))
            chunkIndex += 1
        }

        // Chunk conclusion
        let conclusionChunks = chunkingStrategy.chunk(
            text: episode.conclusion,
            contentType: .conclusion
        )
        for conclusionChunk in conclusionChunks {
            chunks.append(Chunk(
                documentId: document.id,
                chunkIndex: chunkIndex,
                contentType: .conclusion,
                content: conclusionChunk.text,
                tokenCount: conclusionChunk.tokenCount
            ))
            chunkIndex += 1
        }

        // Chunk contradictions if present
        if let contradictions = episode.contradictions, !contradictions.isEmpty {
            chunks.append(Chunk(
                documentId: document.id,
                chunkIndex: chunkIndex,
                contentType: .contradiction,
                content: contradictions,
                tokenCount: chunkingStrategy.estimateTokens(contradictions)
            ))
            chunkIndex += 1
        }

        // Chunk next_question if present
        if let nextQuestion = episode.nextQuestion, !nextQuestion.isEmpty {
            chunks.append(Chunk(
                documentId: document.id,
                chunkIndex: chunkIndex,
                contentType: .nextQuestion,
                content: nextQuestion,
                tokenCount: chunkingStrategy.estimateTokens(nextQuestion)
            ))
        }

        return (document, chunks)
    }

    public func parseRawText(fileURL: URL, text: String, sourceType: SourceType, contentType: ContentType) throws -> (document: Document, chunks: [Chunk]) {
        let createdAt: Date
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let modDate = attributes[.modificationDate] as? Date {
            createdAt = modDate
        } else {
            createdAt = Date()
        }

        let document = Document(
            sourceType: sourceType,
            sourcePath: fileURL.path,
            createdAt: createdAt,
            indexedAt: Date(),
            metadata: [
                "salvaged_raw_text": "true"
            ]
        )

        let chunked = chunkingStrategy.chunk(text: text, contentType: contentType)
        var chunks: [Chunk] = []
        chunks.reserveCapacity(chunked.count)

        for (index, chunk) in chunked.enumerated() {
            chunks.append(Chunk(
                documentId: document.id,
                chunkIndex: index,
                contentType: contentType,
                content: chunk.text,
                tokenCount: chunk.tokenCount
            ))
        }

        return (document, chunks)
    }

    public func loadJSONText(url: URL) throws -> String {
        let rawData = try Data(contentsOf: url)
        if rawData.isEmpty {
            throw CorruptEpisodeFile.empty
        }

        let strippedData = stripLeadingNulls(rawData)
        if strippedData.isEmpty {
            throw CorruptEpisodeFile.empty
        }

        let encoding = detectUTF16Encoding(strippedData)
        let text: String

        if let encoding = encoding {
            guard let decoded = String(data: strippedData, encoding: encoding) else {
                throw CorruptEpisodeFile.invalidUTF16
            }
            text = decoded
        } else {
            guard let decoded = String(data: strippedData, encoding: .utf8) else {
                throw CorruptEpisodeFile.invalidUTF8
            }
            text = decoded
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw CorruptEpisodeFile.empty
        }

        if let firstChar = firstNonWhitespaceChar(in: trimmed) {
            if firstChar != "{" && firstChar != "[" {
                let prefixByte = firstNonWhitespaceByte(in: strippedData)
                throw CorruptEpisodeFile.notJSON(prefixByte: prefixByte)
            }
        } else {
            throw CorruptEpisodeFile.empty
        }

        return trimmed
    }

    private func stripLeadingNulls(_ data: Data) -> Data {
        var index = 0
        while index < data.count && data[index] == 0x00 {
            index += 1
        }
        if index == 0 { return data }
        return data.subdata(in: index..<data.count)
    }

    private func detectUTF16Encoding(_ data: Data) -> String.Encoding? {
        if data.count >= 2 {
            if data[0] == 0xFF && data[1] == 0xFE {
                return .utf16LittleEndian
            }
            if data[0] == 0xFE && data[1] == 0xFF {
                return .utf16BigEndian
            }
        }

        let sampleCount = min(64, data.count)
        if sampleCount < 4 { return nil }

        var nullsEven = 0
        var nullsOdd = 0
        for i in 0..<sampleCount {
            if data[i] == 0x00 {
                if i % 2 == 0 { nullsEven += 1 } else { nullsOdd += 1 }
            }
        }

        let nullRatio = Float(nullsEven + nullsOdd) / Float(sampleCount)
        if nullRatio < 0.3 { return nil }

        if nullsOdd > nullsEven {
            return .utf16LittleEndian
        } else {
            return .utf16BigEndian
        }
    }

    private func firstNonWhitespaceChar(in text: String) -> Character? {
        for char in text {
            if !char.isWhitespace {
                return char
            }
        }
        return nil
    }

    private func firstNonWhitespaceByte(in data: Data) -> UInt8? {
        for byte in data {
            if byte != 0x20 && byte != 0x0A && byte != 0x0D && byte != 0x09 {
                return byte
            }
        }
        return nil
    }
}

public enum CorruptEpisodeFile: LocalizedError {
    case empty
    case notJSON(prefixByte: UInt8?)
    case invalidUTF16
    case invalidUTF8
    case decodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "Empty or whitespace-only file"
        case .notJSON(let prefixByte):
            if let byte = prefixByte {
                return "Not JSON (starts with 0x\(String(format: "%02X", byte)))"
            }
            return "Not JSON"
        case .invalidUTF16:
            return "Invalid UTF-16 encoding"
        case .invalidUTF8:
            return "Invalid UTF-8 encoding"
        case .decodeFailed(let message):
            return "JSON decode failed: \(message)"
        }
    }
}

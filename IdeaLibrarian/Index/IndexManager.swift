import Foundation

public class IndexManager {
    private let store: SQLiteStore
    private let scanner: DocumentScanner
    private let parser: JSONEpisodeParser
    private let pythonParser = PythonFileParser()
    private let swiftParser  = SwiftFileParser()
    private let embeddingProvider: EmbeddingProvider?
    private let batchSize: Int
    private let pathNormalizer = PathNormalizer()

    public init(
        store: SQLiteStore,
        scanner: DocumentScanner,
        parser: JSONEpisodeParser,
        embeddingProvider: EmbeddingProvider? = nil,
        batchSize: Int = 100
    ) {
        self.store = store
        self.scanner = scanner
        self.parser = parser
        self.embeddingProvider = embeddingProvider
        self.batchSize = batchSize
    }

    public func indexDirectory(
        _ url: URL,
        progressCallback: @escaping (IndexProgress) -> Void
    ) async throws {
        let rootPath = pathNormalizer.canonicalPath(for: url)

        // Get all files (canonicalized and de-duplicated by canonical path)
        let scannedFiles = try scanner.scanDirectory(url)
        let allFiles = pathNormalizer.uniqueCanonicalURLs(scannedFiles)

        // Build a canonical-path index of already indexed documents so path string differences
        // (symlinks/aliases) don't cause re-indexing and cascade-deleting embeddings.
        let indexedDocs = try store.getAllDocumentIdsAndPaths()
        var indexedByCanonicalPath: [String: String] = [:]
        indexedByCanonicalPath.reserveCapacity(indexedDocs.count)
        for doc in indexedDocs {
            let canonical = pathNormalizer.canonicalPath(forPath: doc.sourcePath)
            if canonical.hasPrefix(rootPath) {
                indexedByCanonicalPath[canonical] = doc.id
            }
        }

        // Find new files by canonical path
        let newFiles = allFiles.filter { indexedByCanonicalPath[$0.path] == nil }

        guard !newFiles.isEmpty else {
#if DEBUG
            print("Scan summary: total=0, ok=0, bad=0, skippedKnownBad=0")
#endif
            progressCallback(IndexProgress(
                total: allFiles.count,
                indexed: allFiles.count,
                currentFile: nil,
                isIndexing: false
            ))
            return
        }

        // Process in batches
        let total = newFiles.count
        var indexed = 0
        var debugCounters: DebugCounters? = nil
#if DEBUG
        debugCounters = DebugCounters(
            totalJSON: total,
            parsedOK: 0,
            skippedBad: 0,
            skippedKnownBad: 0
        )
#endif

        progressCallback(IndexProgress(
            total: total,
            indexed: indexed,
            currentFile: nil,
            isIndexing: true
        ))

        for batch in newFiles.chunked(into: batchSize) {
            try await processBatch(
                batch,
                total: total,
                indexed: &indexed,
                progressCallback: progressCallback,
                debugCounters: &debugCounters,
                indexedByCanonicalPath: indexedByCanonicalPath
            )
        }

        progressCallback(IndexProgress(
            total: total,
            indexed: indexed,
            currentFile: nil,
            isIndexing: false
        ))

#if DEBUG
        if let counters = debugCounters {
            print("Scan summary: total=\(counters.totalJSON), ok=\(counters.parsedOK), bad=\(counters.skippedBad), skippedKnownBad=\(counters.skippedKnownBad)")
        }
#endif
    }

    private func processBatch(
        _ batch: [URL],
        total: Int,
        indexed: inout Int,
        progressCallback: @escaping (IndexProgress) -> Void,
        debugCounters: inout DebugCounters?,
        indexedByCanonicalPath: [String: String]
    ) async throws {
        for fileURL in batch {
            do {
                let canonicalFileURL = URL(fileURLWithPath: pathNormalizer.canonicalPath(for: fileURL))
                let canonicalPath = canonicalFileURL.path
                let existingDocumentId = indexedByCanonicalPath[canonicalPath] ?? (try? store.getDocumentId(sourcePath: canonicalPath))

                progressCallback(IndexProgress(
                    total: total,
                    indexed: indexed,
                    currentFile: canonicalFileURL.lastPathComponent,
                    isIndexing: true
                ))

                let ext = canonicalFileURL.pathExtension.lowercased()

                // Route Python source files to the dedicated parser
                if ext == "py" {
                    var (document, chunks) = try pythonParser.parse(fileURL: canonicalFileURL)
                    if let existingDocumentId = existingDocumentId, existingDocumentId != document.id {
                        document = Document(
                            id: existingDocumentId,
                            sourceType: document.sourceType,
                            sourcePath: document.sourcePath,
                            metadata: document.metadata
                        )
                        chunks = chunks.map { chunk in
                            Chunk(
                                id: chunk.id,
                                documentId: existingDocumentId,
                                chunkIndex: chunk.chunkIndex,
                                contentType: chunk.contentType,
                                content: chunk.content,
                                tokenCount: chunk.tokenCount
                            )
                        }
                    }
                    try store.insertDocument(document)
                    try store.insertChunks(chunks)
                    indexed += 1
#if DEBUG
                    debugCounters?.parsedOK += 1
#endif
                    continue
                }

                // Route Swift source files to the dedicated parser
                if ext == "swift" {
                    var (document, chunks) = try swiftParser.parse(fileURL: canonicalFileURL)
                    if let existingDocumentId = existingDocumentId, existingDocumentId != document.id {
                        document = Document(
                            id: existingDocumentId,
                            sourceType: document.sourceType,
                            sourcePath: document.sourcePath,
                            metadata: document.metadata
                        )
                        chunks = chunks.map { chunk in
                            Chunk(
                                id: chunk.id,
                                documentId: existingDocumentId,
                                chunkIndex: chunk.chunkIndex,
                                contentType: chunk.contentType,
                                content: chunk.content,
                                tokenCount: chunk.tokenCount
                            )
                        }
                    }
                    try store.insertDocument(document)
                    try store.insertChunks(chunks)
                    indexed += 1
#if DEBUG
                    debugCounters?.parsedOK += 1
#endif
                    continue
                }

                if ext != "json" {
                    let salvaged: String?
                    if ext == "pdf" {
                        salvaged = scanner.extractPDFText(from: canonicalFileURL)
                    } else {
                        salvaged = scanner.salvageText(from: canonicalFileURL)
                    }
                    if let salvaged = salvaged,
                       nonWhitespaceCount(in: salvaged) >= 50 {
                        let sourceType = sourceTypeForExtension(ext)
                        var (document, chunks) = try parser.parseRawText(
                            fileURL: canonicalFileURL,
                            text: salvaged,
                            sourceType: sourceType,
                            contentType: .stage2
                        )
                        if let existingDocumentId = existingDocumentId, existingDocumentId != document.id {
                            document = Document(
                                id: existingDocumentId,
                                sourceType: document.sourceType,
                                sourcePath: document.sourcePath,
                                worldId: document.worldId,
                                evolutionRunId: document.evolutionRunId,
                                createdAt: document.createdAt,
                                indexedAt: document.indexedAt,
                                metadata: document.metadata
                            )
                            chunks = chunks.map { chunk in
                                Chunk(
                                    id: chunk.id,
                                    documentId: existingDocumentId,
                                    chunkIndex: chunk.chunkIndex,
                                    contentType: chunk.contentType,
                                    content: chunk.content,
                                    tokenCount: chunk.tokenCount
                                )
                            }
                        }
                        try store.insertDocument(document)
                        try store.insertChunks(chunks)
                        indexed += 1
#if DEBUG
                        debugCounters?.parsedOK += 1
#endif
                        continue
                    } else {
                        print("Skipping unreadable file: \(canonicalFileURL.lastPathComponent)")
#if DEBUG
                        debugCounters?.skippedBad += 1
#endif
                        indexed += 1
                        continue
                    }
                }

                if let mtime = scanner.getFileModificationDate(canonicalFileURL) {
                    if (try? store.isBadFile(path: canonicalPath, mtime: mtime)) == true {
                        if let salvaged = scanner.salvageText(from: canonicalFileURL),
                           nonWhitespaceCount(in: salvaged) >= 50 {
                            var (document, chunks) = try parser.parseRawText(
                                fileURL: canonicalFileURL,
                                text: salvaged,
                                sourceType: .jsonEpisode,
                                contentType: .stage2
                            )
                            if let existingDocumentId = existingDocumentId, existingDocumentId != document.id {
                                document = Document(
                                    id: existingDocumentId,
                                    sourceType: document.sourceType,
                                    sourcePath: document.sourcePath,
                                    worldId: document.worldId,
                                    evolutionRunId: document.evolutionRunId,
                                    createdAt: document.createdAt,
                                    indexedAt: document.indexedAt,
                                    metadata: document.metadata
                                )
                                chunks = chunks.map { chunk in
                                    Chunk(
                                        id: chunk.id,
                                        documentId: existingDocumentId,
                                        chunkIndex: chunk.chunkIndex,
                                        contentType: chunk.contentType,
                                        content: chunk.content,
                                        tokenCount: chunk.tokenCount
                                    )
                                }
                            }
                            try store.insertDocument(document)
                            try store.insertChunks(chunks)
                            try? store.clearBadFile(path: canonicalPath)
                            print("Salvaged previously bad JSON: \(canonicalFileURL.lastPathComponent)")
                            indexed += 1
#if DEBUG
                            debugCounters?.parsedOK += 1
#endif
                            continue
                        }
#if DEBUG
                        debugCounters?.skippedKnownBad += 1
#endif
                        print("Skipping known bad JSON: \(canonicalFileURL.lastPathComponent)")
                        indexed += 1
                        continue
                    }
                }

                // Parse episode
                var (document, chunks) = try parser.parse(fileURL: canonicalFileURL)
                if let existingDocumentId = existingDocumentId, existingDocumentId != document.id {
                    document = Document(
                        id: existingDocumentId,
                        sourceType: document.sourceType,
                        sourcePath: document.sourcePath,
                        worldId: document.worldId,
                        evolutionRunId: document.evolutionRunId,
                        createdAt: document.createdAt,
                        indexedAt: document.indexedAt,
                        metadata: document.metadata
                    )
                    chunks = chunks.map { chunk in
                        Chunk(
                            id: chunk.id,
                            documentId: existingDocumentId,
                            chunkIndex: chunk.chunkIndex,
                            contentType: chunk.contentType,
                            content: chunk.content,
                            tokenCount: chunk.tokenCount
                        )
                    }
                }

                // Store in database
                try store.insertDocument(document)
                try store.insertChunks(chunks)
                try? store.clearBadFile(path: canonicalPath)

                indexed += 1
#if DEBUG
                debugCounters?.parsedOK += 1
#endif
            } catch {
                if shouldAttemptSalvage(error: error) {
                    let canonicalFileURL = URL(fileURLWithPath: pathNormalizer.canonicalPath(for: fileURL))
                    let canonicalPath = canonicalFileURL.path
                    let existingDocumentId = indexedByCanonicalPath[canonicalPath] ?? (try? store.getDocumentId(sourcePath: canonicalPath))

                    if let salvaged = scanner.salvageText(from: canonicalFileURL),
                       nonWhitespaceCount(in: salvaged) >= 50 {
                        var (document, chunks) = try parser.parseRawText(
                            fileURL: canonicalFileURL,
                            text: salvaged,
                            sourceType: .jsonEpisode,
                            contentType: .stage2
                        )
                        if let existingDocumentId = existingDocumentId, existingDocumentId != document.id {
                            document = Document(
                                id: existingDocumentId,
                                sourceType: document.sourceType,
                                sourcePath: document.sourcePath,
                                worldId: document.worldId,
                                evolutionRunId: document.evolutionRunId,
                                createdAt: document.createdAt,
                                indexedAt: document.indexedAt,
                                metadata: document.metadata
                            )
                            chunks = chunks.map { chunk in
                                Chunk(
                                    id: chunk.id,
                                    documentId: existingDocumentId,
                                    chunkIndex: chunk.chunkIndex,
                                    contentType: chunk.contentType,
                                    content: chunk.content,
                                    tokenCount: chunk.tokenCount
                                )
                            }
                        }
                        try store.insertDocument(document)
                        try store.insertChunks(chunks)
                        try? store.clearBadFile(path: canonicalPath)
                        print("Salvaged JSON as raw text: \(canonicalFileURL.lastPathComponent)")
                        indexed += 1
#if DEBUG
                        debugCounters?.parsedOK += 1
#endif
                        continue
                    } else {
                        let shortReason = "unreadable/corrupt json (no salvageable text)"
                        let mtime = scanner.getFileModificationDate(canonicalFileURL) ?? Date()
                        try? store.upsertBadFile(path: canonicalPath, mtime: mtime, error: shortReason)
                        print("Skipping bad JSON: \(canonicalFileURL.lastPathComponent) — \(shortReason)")
#if DEBUG
                        debugCounters?.skippedBad += 1
#endif
                    }
                } else if let corrupt = error as? CorruptEpisodeFile {
                    let shortReason = corrupt.errorDescription ?? error.localizedDescription
                    let canonicalFileURL = URL(fileURLWithPath: pathNormalizer.canonicalPath(for: fileURL))
                    let canonicalPath = canonicalFileURL.path
                    let mtime = scanner.getFileModificationDate(canonicalFileURL) ?? Date()
                    try? store.upsertBadFile(path: canonicalPath, mtime: mtime, error: shortReason)
                    print("Skipping bad JSON: \(canonicalFileURL.lastPathComponent) — \(shortReason)")
#if DEBUG
                    debugCounters?.skippedBad += 1
#endif
                } else {
                    // Log error but continue processing
                    let canonicalFileURL = URL(fileURLWithPath: pathNormalizer.canonicalPath(for: fileURL))
                    print("Error indexing \(canonicalFileURL.path): \(error)")
                }

                progressCallback(IndexProgress(
                    total: total,
                    indexed: indexed,
                    currentFile: fileURL.lastPathComponent,
                    isIndexing: true,
                    error: error
                ))
                indexed += 1
            }
        }
    }

    public func getStatistics() throws -> DatabaseStatistics {
        return try store.getStatistics()
    }

    // MARK: - Embedding Generation

	    public func generateEmbeddings(
	        progressCallback: @escaping (IndexProgress) -> Void
	    ) async throws {
        guard let embeddingProvider = embeddingProvider else {
            throw IndexError.embeddingProviderNotConfigured
        }

        // Get all chunks without embeddings
        let stats = try store.getStatistics()
        let chunksWithoutEmbeddings = try getChunksWithoutEmbeddings()

        guard !chunksWithoutEmbeddings.isEmpty else {
            progressCallback(IndexProgress(
                total: stats.chunkCount,
                indexed: stats.embeddingCount,
                currentFile: nil,
                isIndexing: false
            ))
            return
        }

        let total = chunksWithoutEmbeddings.count
        var indexed = 0

        progressCallback(IndexProgress(
            total: total,
            indexed: indexed,
            currentFile: "Generating embeddings...",
            isIndexing: true
        ))

	        // Process in batches
	        for batch in chunksWithoutEmbeddings.chunked(into: batchSize) {
	            let texts = batch.map { $0.content }
	            let embeddings = try await embeddingProvider.embedBatch(texts: texts)

	            // Autosave each embedding immediately (no batch transaction).
	            for (chunk, embedding) in zip(batch, embeddings) {
	                let embeddingObj = Embedding(
	                    chunkId: chunk.id,
	                    modelName: "text-embedding-3-small",
	                    embedding: embedding
	                )
	                try store.insertEmbedding(embeddingObj)
	                indexed += 1
	            }

	            progressCallback(IndexProgress(
	                total: total,
	                indexed: indexed,
	                currentFile: "Generated \(indexed)/\(total) embeddings",
	                isIndexing: true
	            ))
	        }

        progressCallback(IndexProgress(
            total: total,
            indexed: indexed,
            currentFile: nil,
            isIndexing: false
        ))
    }

    private func getChunksWithoutEmbeddings() throws -> [Chunk] {
        return try store.getChunksWithoutEmbeddings()
    }
}

public enum IndexError: LocalizedError {
    case embeddingProviderNotConfigured

    public var errorDescription: String? {
        switch self {
        case .embeddingProviderNotConfigured:
            return "Embedding provider not configured. Please provide an OpenAI API key."
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

private struct DebugCounters {
    var totalJSON: Int
    var parsedOK: Int
    var skippedBad: Int
    var skippedKnownBad: Int
}

private func sourceTypeForExtension(_ ext: String) -> SourceType {
    switch ext {
    case "pdf":
        return .pdf
    case "py":
        return .pythonSource
    case "swift":
        return .swiftSource
    case "txt", "md", "docx":
        return .transcript
    default:
        return .transcript
    }
}

private func shouldAttemptSalvage(error: Error) -> Bool {
    if error is DecodingError { return true }
    if error is CorruptEpisodeFile { return true }
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain && nsError.code == 3840 {
        return true
    }
    return false
}

private func nonWhitespaceCount(in text: String) -> Int {
    return text.reduce(0) { count, char in
        char.isWhitespace ? count : count + 1
    }
}

private final class PathNormalizer {
    func canonicalPath(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    func canonicalPath(forPath path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    func uniqueCanonicalURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var output: [URL] = []
        output.reserveCapacity(urls.count)

        for url in urls {
            let canonical = canonicalPath(for: url)
            if seen.insert(canonical).inserted {
                output.append(URL(fileURLWithPath: canonical))
            }
        }

        return output.sorted { $0.path < $1.path }
    }
}

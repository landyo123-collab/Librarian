import Foundation
import SQLite3

// SQLite transient destructor
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public class SQLiteStore {
    private var db: OpaquePointer?
    private let dbPath: String
    private let queue = DispatchQueue(label: "com.librarian.sqlite", attributes: .concurrent)

    public init(path: String) throws {
        self.dbPath = path
        try openDatabase()
        try createSchema()
    }

    deinit {
        closeDatabase()
    }

    public var databasePath: String {
        return dbPath
    }

    // MARK: - Database Lifecycle

    private func openDatabase() throws {
        var db: OpaquePointer?
        if sqlite3_open_v2(
            dbPath,
            &db,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) != SQLITE_OK {
            throw SQLiteError.cannotOpen(dbPath)
        }
        self.db = db

        // Enable foreign keys
        try execute("PRAGMA foreign_keys = ON")

        // Performance optimizations
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA cache_size = -64000") // 64MB cache
        try execute("PRAGMA temp_store = MEMORY")
    }

    private func closeDatabase() {
        sqlite3_close(db)
        db = nil
    }

    // MARK: - Schema Creation

    private func createSchema() throws {
        let version = try getCurrentSchemaVersion()

        if version == 0 {
            try createInitialSchema()
            try setSchemaVersion(1)
        }

        // Ensure bad_files exists even for existing databases
        try execute("""
            CREATE TABLE IF NOT EXISTS bad_files (
                path TEXT PRIMARY KEY,
                mtime REAL NOT NULL,
                error TEXT NOT NULL,
                last_seen_at REAL NOT NULL
            )
        """)

        // Ensure concept_notes cache exists
        try execute("""
            CREATE TABLE IF NOT EXISTS concept_notes (
                term TEXT PRIMARY KEY,
                note TEXT NOT NULL,
                updated_at REAL NOT NULL
            )
        """)

        try execute("""
            CREATE TABLE IF NOT EXISTS concept_note_sources (
                term TEXT NOT NULL,
                chunk_id TEXT NOT NULL,
                PRIMARY KEY (term, chunk_id),
                FOREIGN KEY (term) REFERENCES concept_notes(term) ON DELETE CASCADE
            )
        """)

        // Future migrations would go here
        // if version < 2 { try migrateToV2() }
    }

    private func createInitialSchema() throws {
        // Documents table
        try execute("""
            CREATE TABLE IF NOT EXISTS documents (
                id TEXT PRIMARY KEY,
                source_type TEXT NOT NULL,
                source_path TEXT NOT NULL UNIQUE,
                world_id TEXT,
                evolution_run_id TEXT,
                created_at REAL NOT NULL,
                indexed_at REAL NOT NULL,
                metadata_json TEXT
            )
        """)

        // Chunks table
        try execute("""
            CREATE TABLE IF NOT EXISTS chunks (
                id TEXT PRIMARY KEY,
                document_id TEXT NOT NULL,
                chunk_index INTEGER NOT NULL,
                content_type TEXT NOT NULL,
                content TEXT NOT NULL,
                token_count INTEGER NOT NULL,
                FOREIGN KEY (document_id) REFERENCES documents(id) ON DELETE CASCADE,
                UNIQUE(document_id, chunk_index)
            )
        """)

        // FTS5 virtual table for full-text search
        try execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
                chunk_id UNINDEXED,
                content,
                content=chunks,
                content_rowid=rowid,
                tokenize='porter unicode61'
            )
        """)

        // Triggers to keep FTS5 in sync
        try execute("""
            CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
                INSERT INTO chunks_fts(rowid, chunk_id, content)
                VALUES (new.rowid, new.id, new.content);
            END
        """)

        try execute("""
            CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
                INSERT INTO chunks_fts(chunks_fts, rowid, chunk_id, content)
                VALUES ('delete', old.rowid, old.id, old.content);
            END
        """)

        try execute("""
            CREATE TRIGGER IF NOT EXISTS chunks_au AFTER UPDATE ON chunks BEGIN
                INSERT INTO chunks_fts(chunks_fts, rowid, chunk_id, content)
                VALUES ('delete', old.rowid, old.id, old.content);
                INSERT INTO chunks_fts(rowid, chunk_id, content)
                VALUES (new.rowid, new.id, new.content);
            END
        """)

        // Embeddings table
        try execute("""
            CREATE TABLE IF NOT EXISTS embeddings (
                chunk_id TEXT PRIMARY KEY,
                model_name TEXT NOT NULL,
                embedding BLOB NOT NULL,
                created_at REAL NOT NULL,
                FOREIGN KEY (chunk_id) REFERENCES chunks(id) ON DELETE CASCADE
            )
        """)

        // AtlasNotes table
        try execute("""
            CREATE TABLE IF NOT EXISTS atlas_notes (
                id TEXT PRIMARY KEY,
                query TEXT NOT NULL,
                summary TEXT NOT NULL,
                key_concepts TEXT NOT NULL,
                source_chunk_ids TEXT NOT NULL,
                created_at REAL NOT NULL,
                retrieval_boost REAL NOT NULL
            )
        """)

        // Bad files table
        try execute("""
            CREATE TABLE IF NOT EXISTS bad_files (
                path TEXT PRIMARY KEY,
                mtime REAL NOT NULL,
                error TEXT NOT NULL,
                last_seen_at REAL NOT NULL
            )
        """)

        // Concepts table
        try execute("""
            CREATE TABLE IF NOT EXISTS concepts (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL UNIQUE,
                definition TEXT,
                first_seen REAL NOT NULL,
                occurrence_count INTEGER NOT NULL
            )
        """)

        // Concept relations table
        try execute("""
            CREATE TABLE IF NOT EXISTS concept_relations (
                id TEXT PRIMARY KEY,
                source_concept_id TEXT NOT NULL,
                target_concept_id TEXT NOT NULL,
                relation_type TEXT NOT NULL,
                evidence_chunk_id TEXT,
                confidence REAL NOT NULL,
                created_at REAL NOT NULL,
                FOREIGN KEY (source_concept_id) REFERENCES concepts(id) ON DELETE CASCADE,
                FOREIGN KEY (target_concept_id) REFERENCES concepts(id) ON DELETE CASCADE,
                FOREIGN KEY (evidence_chunk_id) REFERENCES chunks(id) ON DELETE SET NULL
            )
        """)

        // Conversations table
        try execute("""
            CREATE TABLE IF NOT EXISTS conversations (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
        """)

        // Messages table
        try execute("""
            CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY,
                conversation_id TEXT NOT NULL,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                source_chunks TEXT,
                ccr_score REAL,
                created_at REAL NOT NULL,
                FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
            )
        """)

        // Create indexes
        try execute("CREATE INDEX IF NOT EXISTS idx_chunks_document ON chunks(document_id)")
        try execute("CREATE INDEX IF NOT EXISTS idx_documents_created ON documents(created_at)")
        try execute("CREATE INDEX IF NOT EXISTS idx_messages_conversation ON messages(conversation_id)")
        try execute("CREATE INDEX IF NOT EXISTS idx_concept_relations_source ON concept_relations(source_concept_id)")
        try execute("CREATE INDEX IF NOT EXISTS idx_concept_relations_target ON concept_relations(target_concept_id)")
    }

    // MARK: - Schema Versioning

    private func getCurrentSchemaVersion() throws -> Int {
        try execute("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER)")
        let query = "SELECT version FROM schema_version LIMIT 1"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        if sqlite3_step(statement) == SQLITE_ROW {
            return Int(sqlite3_column_int(statement, 0))
        }
        return 0
    }

    private func setSchemaVersion(_ version: Int) throws {
        try execute("DELETE FROM schema_version")
        try execute("INSERT INTO schema_version (version) VALUES (\(version))")
    }

    // MARK: - Document Operations

    public func insertDocument(_ document: Document) throws {
        let metadataJSON = try JSONEncoder().encode(document.metadata)
        let metadataString = String(data: metadataJSON, encoding: .utf8) ?? "{}"

        try execute("""
            INSERT INTO documents
            (id, source_type, source_path, world_id, evolution_run_id, created_at, indexed_at, metadata_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_path) DO UPDATE SET
                source_type = excluded.source_type,
                world_id = excluded.world_id,
                evolution_run_id = excluded.evolution_run_id,
                created_at = excluded.created_at,
                indexed_at = excluded.indexed_at,
                metadata_json = excluded.metadata_json
        """, parameters: [
            document.id,
            document.sourceType.rawValue,
            document.sourcePath,
            document.worldId as Any,
            document.evolutionRunId as Any,
            document.createdAt.timeIntervalSince1970,
            document.indexedAt.timeIntervalSince1970,
            metadataString
        ])
    }

    public func getDocumentId(sourcePath: String) throws -> String? {
        let query = "SELECT id FROM documents WHERE source_path = ? LIMIT 1"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, sourcePath, -1, SQLITE_TRANSIENT)

        if sqlite3_step(statement) == SQLITE_ROW {
            return String(cString: sqlite3_column_text(statement, 0))
        }
        return nil
    }

    public func getDocument(id: String) throws -> Document? {
        let query = "SELECT * FROM documents WHERE id = ?"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)

        if sqlite3_step(statement) == SQLITE_ROW {
            return try parseDocument(from: statement!)
        }
        return nil
    }

    public func getIndexedDocumentPaths() throws -> Set<String> {
        let query = "SELECT source_path FROM documents"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var paths = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let cString = sqlite3_column_text(statement, 0) {
                paths.insert(String(cString: cString))
            }
        }
        return paths
    }

    public func getAllDocumentIdsAndPaths() throws -> [(id: String, sourcePath: String)] {
        let query = "SELECT id, source_path FROM documents"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var results: [(id: String, sourcePath: String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(statement, 0))
            let sourcePath = String(cString: sqlite3_column_text(statement, 1))
            results.append((id: id, sourcePath: sourcePath))
        }
        return results
    }

    private func parseDocument(from statement: OpaquePointer) throws -> Document {
        let id = String(cString: sqlite3_column_text(statement, 0))
        let sourceType = SourceType(rawValue: String(cString: sqlite3_column_text(statement, 1)))!
        let sourcePath = String(cString: sqlite3_column_text(statement, 2))
        let worldId = sqlite3_column_text(statement, 3).map { String(cString: $0) }
        let evolutionRunId = sqlite3_column_text(statement, 4).map { String(cString: $0) }
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
        let indexedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
        let metadataString = String(cString: sqlite3_column_text(statement, 7))
        let metadata = (try? JSONDecoder().decode([String: String].self, from: metadataString.data(using: .utf8)!)) ?? [:]

        return Document(
            id: id,
            sourceType: sourceType,
            sourcePath: sourcePath,
            worldId: worldId,
            evolutionRunId: evolutionRunId,
            createdAt: createdAt,
            indexedAt: indexedAt,
            metadata: metadata
        )
    }

    // MARK: - Chunk Operations

    public func insertChunks(_ chunks: [Chunk]) throws {
        try insertChunks(chunks, inTransaction: true)
    }

    public func insertChunks(_ chunks: [Chunk], inTransaction: Bool) throws {
        var shouldCommit = false
        if inTransaction {
            try beginTransaction()
            shouldCommit = true
        }
        defer {
            if shouldCommit {
                try? commitTransaction()
            }
        }

        for chunk in chunks {
            try execute("""
                INSERT INTO chunks
                (id, document_id, chunk_index, content_type, content, token_count)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(document_id, chunk_index) DO UPDATE SET
                    content_type = excluded.content_type,
                    content = excluded.content,
                    token_count = excluded.token_count
            """, parameters: [
                chunk.id,
                chunk.documentId,
                chunk.chunkIndex,
                chunk.contentType.rawValue,
                chunk.content,
                chunk.tokenCount
            ])
        }
    }

    public func getChunks(forDocumentId documentId: String) throws -> [Chunk] {
        let query = "SELECT * FROM chunks WHERE document_id = ? ORDER BY chunk_index"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, documentId, -1, SQLITE_TRANSIENT)

        var chunks: [Chunk] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            chunks.append(try parseChunk(from: statement!))
        }
        return chunks
    }

    public func getChunk(id: String) throws -> Chunk? {
        let query = "SELECT * FROM chunks WHERE id = ?"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)

        if sqlite3_step(statement) == SQLITE_ROW {
            return try parseChunk(from: statement!)
        }
        return nil
    }

    public func getAllChunks() throws -> [Chunk] {
        let query = "SELECT * FROM chunks ORDER BY document_id, chunk_index"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var chunks: [Chunk] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            chunks.append(try parseChunk(from: statement!))
        }
        return chunks
    }

    public func getChunksWithoutEmbeddings() throws -> [Chunk] {
        let query = """
            SELECT c.* FROM chunks c
            LEFT JOIN embeddings e ON c.id = e.chunk_id
            WHERE e.chunk_id IS NULL
            ORDER BY c.document_id, c.chunk_index
        """
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var chunks: [Chunk] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            chunks.append(try parseChunk(from: statement!))
        }
        return chunks
    }

    private func parseChunk(from statement: OpaquePointer) throws -> Chunk {
        let id = String(cString: sqlite3_column_text(statement, 0))
        let documentId = String(cString: sqlite3_column_text(statement, 1))
        let chunkIndex = Int(sqlite3_column_int(statement, 2))
        let contentType = ContentType(rawValue: String(cString: sqlite3_column_text(statement, 3)))!
        let content = String(cString: sqlite3_column_text(statement, 4))
        let tokenCount = Int(sqlite3_column_int(statement, 5))

        return Chunk(
            id: id,
            documentId: documentId,
            chunkIndex: chunkIndex,
            contentType: contentType,
            content: content,
            tokenCount: tokenCount
        )
    }

    // MARK: - Full-Text Search

    public func searchChunks(query: String, limit: Int = 50) throws -> [String] {
        let sql = """
            SELECT chunk_id FROM chunks_fts
            WHERE chunks_fts MATCH ?
            ORDER BY bm25(chunks_fts)
            LIMIT ?
        """
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, query, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var chunkIds: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let cString = sqlite3_column_text(statement, 0) {
                chunkIds.append(String(cString: cString))
            }
        }
        return chunkIds
    }

    // MARK: - Corpus Browser

    public func countCorpusChunks(filter: CorpusChunkFilter) throws -> Int {
        switch filter {
        case .all:
            return try count(table: "chunks")
        case .embeddedOnly:
            return try count(table: "embeddings")
        case .withoutEmbeddings:
            let sql = """
                SELECT COUNT(*) FROM chunks c
                LEFT JOIN embeddings e ON e.chunk_id = c.id
                WHERE e.chunk_id IS NULL
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SQLiteError.prepareError(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            if sqlite3_step(statement) == SQLITE_ROW {
                return Int(sqlite3_column_int(statement, 0))
            }
            return 0
        }
    }

    /// Page through chunks without loading embedding vectors. This is designed for UI browsing.
    public func getCorpusChunks(
        filter: CorpusChunkFilter,
        limit: Int,
        offset: Int
    ) throws -> [ChunkCorpusRow] {
        let whereClause: String = {
            switch filter {
            case .all: return ""
            case .embeddedOnly: return "WHERE e.chunk_id IS NOT NULL"
            case .withoutEmbeddings: return "WHERE e.chunk_id IS NULL"
            }
        }()

        let sql = """
            SELECT
                c.id,
                c.document_id,
                c.chunk_index,
                c.content_type,
                c.content,
                c.token_count,
                e.model_name,
                e.created_at
            FROM chunks c
            LEFT JOIN embeddings e ON e.chunk_id = c.id
            \(whereClause)
            ORDER BY c.rowid
            LIMIT ? OFFSET ?
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(max(0, limit)))
        sqlite3_bind_int(statement, 2, Int32(max(0, offset)))

        var rows: [ChunkCorpusRow] = []
        rows.reserveCapacity(min(limit, 2000))

        while sqlite3_step(statement) == SQLITE_ROW {
            let chunkId = String(cString: sqlite3_column_text(statement, 0))
            let documentId = String(cString: sqlite3_column_text(statement, 1))
            let chunkIndex = Int(sqlite3_column_int(statement, 2))
            let contentTypeRaw = String(cString: sqlite3_column_text(statement, 3))
            let contentType = ContentType(rawValue: contentTypeRaw) ?? .stage2
            let content = String(cString: sqlite3_column_text(statement, 4))
            let tokenCount = Int(sqlite3_column_int(statement, 5))

            let modelName: String? = {
                guard let ptr = sqlite3_column_text(statement, 6) else { return nil }
                return String(cString: ptr)
            }()
            let createdAt: Date? = {
                if sqlite3_column_type(statement, 7) == SQLITE_NULL { return nil }
                return Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
            }()

            rows.append(ChunkCorpusRow(
                chunkId: chunkId,
                documentId: documentId,
                chunkIndex: chunkIndex,
                contentType: contentType,
                tokenCount: tokenCount,
                content: content,
                hasEmbedding: modelName != nil,
                embeddingModelName: modelName,
                embeddingCreatedAt: createdAt
            ))
        }

        return rows
    }

    // MARK: - Embedding Operations

    public func insertEmbedding(_ embedding: Embedding) throws {
        let blob = embedding.embedding.withUnsafeBytes { Data($0) }

        try execute("""
            INSERT OR REPLACE INTO embeddings
            (chunk_id, model_name, embedding, created_at)
            VALUES (?, ?, ?, ?)
        """, parameters: [
            embedding.chunkId,
            embedding.modelName,
            blob,
            embedding.createdAt.timeIntervalSince1970
        ])
    }

    public func getEmbedding(chunkId: String) throws -> Embedding? {
        let query = "SELECT * FROM embeddings WHERE chunk_id = ?"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, chunkId, -1, SQLITE_TRANSIENT)

        if sqlite3_step(statement) == SQLITE_ROW {
            return try parseEmbedding(from: statement!)
        }
        return nil
    }

    public func getAllEmbeddings() throws -> [Embedding] {
        let query = "SELECT * FROM embeddings"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var embeddings: [Embedding] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            embeddings.append(try parseEmbedding(from: statement!))
        }
        return embeddings
    }

    private func parseEmbedding(from statement: OpaquePointer) throws -> Embedding {
        let chunkId = String(cString: sqlite3_column_text(statement, 0))
        let modelName = String(cString: sqlite3_column_text(statement, 1))
        let blob = sqlite3_column_blob(statement, 2)!
        let blobSize = Int(sqlite3_column_bytes(statement, 2))
        let data = Data(bytes: blob, count: blobSize)
        let embedding = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))

        return Embedding(
            chunkId: chunkId,
            modelName: modelName,
            embedding: embedding,
            createdAt: createdAt
        )
    }

    // MARK: - AtlasNote Operations

    public func insertAtlasNote(_ note: AtlasNote) throws {
        let conceptsJSON = try encodeStringArray(normalizeStringArray(note.keyConcepts))
        let sourceIdsJSON = try encodeStringArray(normalizeStringArray(note.sourceChunkIds))

        try execute("""
            INSERT OR REPLACE INTO atlas_notes
            (id, query, summary, key_concepts, source_chunk_ids, created_at, retrieval_boost)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, parameters: [
            note.id,
            note.query,
            note.summary,
            conceptsJSON,
            sourceIdsJSON,
            note.createdAt.timeIntervalSince1970,
            Double(note.retrievalBoost)
        ])
    }

    public func getAtlasNote(id: String) throws -> AtlasNote? {
        let query = "SELECT * FROM atlas_notes WHERE id = ?"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)

        if sqlite3_step(statement) == SQLITE_ROW {
            return try parseAtlasNote(from: statement!)
        }
        return nil
    }

    public func atlasNoteExists(query: String, sourceChunkIds: [String]) throws -> Bool {
        let sourceIdsJSON = try encodeStringArray(normalizeStringArray(sourceChunkIds))
        let sql = "SELECT 1 FROM atlas_notes WHERE query = ? AND source_chunk_ids = ? LIMIT 1"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, query, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, sourceIdsJSON, -1, SQLITE_TRANSIENT)

        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func parseAtlasNote(from statement: OpaquePointer) throws -> AtlasNote {
        let id = String(cString: sqlite3_column_text(statement, 0))
        let query = String(cString: sqlite3_column_text(statement, 1))
        let summary = String(cString: sqlite3_column_text(statement, 2))
        let conceptsString = String(cString: sqlite3_column_text(statement, 3))
        let sourceIdsString = String(cString: sqlite3_column_text(statement, 4))
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
        let retrievalBoost = Float(sqlite3_column_double(statement, 6))

        let keyConcepts = decodeStringArray(conceptsString)
        let sourceChunkIds = decodeStringArray(sourceIdsString)

        return AtlasNote(
            id: id,
            query: query,
            summary: summary,
            keyConcepts: keyConcepts,
            sourceChunkIds: sourceChunkIds,
            createdAt: createdAt,
            retrievalBoost: retrievalBoost
        )
    }

    private func encodeStringArray(_ values: [String]) throws -> String {
        let data = try JSONEncoder().encode(values)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func decodeStringArray(_ value: String) -> [String] {
        guard let data = value.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func normalizeStringArray(_ values: [String]) -> [String] {
        let unique = Set(values)
        return unique.sorted()
    }

    /// Search AtlasNotes by query text (searches summary and key_concepts)
    public func searchAtlasNotes(query: String, limit: Int = 10) throws -> [AtlasNote] {
        // Simple LIKE search on summary and query fields
        // Note: For better performance, consider adding FTS on atlas_notes
        let sql = """
            SELECT * FROM atlas_notes
            WHERE summary LIKE ? OR query LIKE ? OR key_concepts LIKE ?
            ORDER BY created_at DESC
            LIMIT ?
        """
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        let pattern = "%\(query)%"
        sqlite3_bind_text(statement, 1, pattern, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, pattern, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, pattern, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(statement, 4, Int32(limit))

        var notes: [AtlasNote] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            notes.append(try parseAtlasNote(from: statement!))
        }
        return notes
    }

    /// Get all AtlasNotes ordered by recency
    public func getAllAtlasNotes(limit: Int = 100) throws -> [AtlasNote] {
        let sql = "SELECT * FROM atlas_notes ORDER BY created_at DESC LIMIT ?"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(limit))

        var notes: [AtlasNote] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            notes.append(try parseAtlasNote(from: statement!))
        }
        return notes
    }

    // MARK: - Conversation & Message Operations

    public func insertConversation(_ conversation: Conversation) throws {
        try execute("""
            INSERT INTO conversations
            (id, title, created_at, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at
        """, parameters: [
            conversation.id,
            conversation.title,
            conversation.createdAt.timeIntervalSince1970,
            conversation.updatedAt.timeIntervalSince1970
        ])
    }

    public func getConversations(limit: Int = 50) throws -> [Conversation] {
        let sql = """
            SELECT id, title, created_at, updated_at
            FROM conversations
            ORDER BY updated_at DESC
            LIMIT ?
        """
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(limit))

        var conversations: [Conversation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(statement, 0))
            let title = String(cString: sqlite3_column_text(statement, 1))
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            conversations.append(Conversation(id: id, title: title, createdAt: createdAt, updatedAt: updatedAt))
        }
        return conversations
    }

    public func getConversation(id: String) throws -> Conversation? {
        let sql = "SELECT id, title, created_at, updated_at FROM conversations WHERE id = ?"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)

        if sqlite3_step(statement) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(statement, 0))
            let title = String(cString: sqlite3_column_text(statement, 1))
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            return Conversation(id: id, title: title, createdAt: createdAt, updatedAt: updatedAt)
        }
        return nil
    }

    public func updateConversationTitle(id: String, title: String) throws {
        try execute("""
            UPDATE conversations SET title = ?, updated_at = ? WHERE id = ?
        """, parameters: [title, Date().timeIntervalSince1970, id])
    }

    public func insertMessage(_ message: ChatMessage) throws {
        let sourceChunksJSON: String? = message.sourceChunks.isEmpty ? nil : (try? encodeStringArray(message.sourceChunks))

        try execute("""
            INSERT OR REPLACE INTO messages
            (id, conversation_id, role, content, source_chunks, ccr_score, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, parameters: [
            message.id,
            message.conversationId,
            message.role.rawValue,
            message.content,
            sourceChunksJSON as Any,
            message.ccrScore as Any,
            message.createdAt.timeIntervalSince1970
        ])
    }

    public func getRecentMessages(conversationId: String, limit: Int = 10) throws -> [ChatMessage] {
        let sql = """
            SELECT id, conversation_id, role, content, source_chunks, ccr_score, created_at
            FROM messages
            WHERE conversation_id = ?
            ORDER BY created_at DESC
            LIMIT ?
        """
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, conversationId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var messages: [ChatMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(statement, 0))
            let convId = String(cString: sqlite3_column_text(statement, 1))
            let roleStr = String(cString: sqlite3_column_text(statement, 2))
            let content = String(cString: sqlite3_column_text(statement, 3))
            let sourceChunksStr = sqlite3_column_text(statement, 4).map { String(cString: $0) }
            let ccrScore = sqlite3_column_type(statement, 5) != SQLITE_NULL
                ? Float(sqlite3_column_double(statement, 5)) : nil
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))

            let role = MessageRole(rawValue: roleStr) ?? .user
            let sourceChunks = sourceChunksStr.flatMap { decodeStringArray($0) } ?? []

            messages.append(ChatMessage(
                id: id,
                conversationId: convId,
                role: role,
                content: content,
                sourceChunks: sourceChunks,
                ccrScore: ccrScore,
                createdAt: createdAt
            ))
        }

        // Return in chronological order (oldest first)
        return messages.reversed()
    }

    public func updateConversationTimestamp(id: String) throws {
        try execute("""
            UPDATE conversations SET updated_at = ? WHERE id = ?
        """, parameters: [Date().timeIntervalSince1970, id])
    }

    // MARK: - Bad File Registry

    public func upsertBadFile(path: String, mtime: Date, error: String) throws {
        let sql = """
            INSERT INTO bad_files (path, mtime, error, last_seen_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                mtime = excluded.mtime,
                error = excluded.error,
                last_seen_at = excluded.last_seen_at
        """
        try execute(sql, parameters: [
            path,
            mtime.timeIntervalSince1970,
            error,
            Date().timeIntervalSince1970
        ])
    }

    public func isBadFile(path: String, mtime: Date) throws -> Bool {
        let query = "SELECT mtime FROM bad_files WHERE path = ? LIMIT 1"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, path, -1, SQLITE_TRANSIENT)

        if sqlite3_step(statement) == SQLITE_ROW {
            let stored = sqlite3_column_double(statement, 0)
            let current = mtime.timeIntervalSince1970
            if abs(stored - current) < 0.5 {
                try execute("UPDATE bad_files SET last_seen_at = ? WHERE path = ?", parameters: [
                    Date().timeIntervalSince1970,
                    path
                ])
                return true
            }
        }
        return false
    }

    public func clearBadFile(path: String) throws {
        try execute("DELETE FROM bad_files WHERE path = ?", parameters: [path])
    }

    // MARK: - Concept Note Cache

    public func upsertConceptNote(term: String, note: String, chunkIds: [String] = []) throws {
        let now = Date().timeIntervalSince1970
        try execute("""
            INSERT INTO concept_notes (term, note, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(term) DO UPDATE SET
                note = excluded.note,
                updated_at = excluded.updated_at
        """, parameters: [term, note, now])

        try execute("DELETE FROM concept_note_sources WHERE term = ?", parameters: [term])
        for chunkId in chunkIds {
            try execute("""
                INSERT OR IGNORE INTO concept_note_sources (term, chunk_id)
                VALUES (?, ?)
            """, parameters: [term, chunkId])
        }
    }

    public func getConceptNote(term: String) throws -> (note: String, updatedAt: Date)? {
        let query = "SELECT note, updated_at FROM concept_notes WHERE term = ?"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, term, -1, SQLITE_TRANSIENT)

        if sqlite3_step(statement) == SQLITE_ROW {
            let note = String(cString: sqlite3_column_text(statement, 0))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            return (note, updatedAt)
        }
        return nil
    }

    // MARK: - Transaction Support

    public func beginTransaction() throws {
        try execute("BEGIN TRANSACTION")
    }

    public func commitTransaction() throws {
        try execute("COMMIT")
    }

    public func rollbackTransaction() throws {
        try execute("ROLLBACK")
    }

    // MARK: - Statistics

    public func getStatistics() throws -> DatabaseStatistics {
        let documentCount = try count(table: "documents")
        let chunkCount = try count(table: "chunks")
        let embeddingCount = try count(table: "embeddings")
        let savedNoteCount = try count(table: "atlas_notes")
        let conceptCount = try count(table: "concepts")

        return DatabaseStatistics(
            documentCount: documentCount,
            chunkCount: chunkCount,
            embeddingCount: embeddingCount,
            savedNoteCount: savedNoteCount,
            conceptCount: conceptCount
        )
    }

    public func countRows(table: String) throws -> Int {
        return try count(table: table)
    }

    public func countDocuments(sourceType: SourceType? = nil) throws -> Int {
        if let sourceType = sourceType {
            let sql = "SELECT COUNT(*) FROM documents WHERE source_type = ?"
            var statement: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SQLiteError.prepareError(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, sourceType.rawValue, -1, SQLITE_TRANSIENT)
            if sqlite3_step(statement) == SQLITE_ROW {
                return Int(sqlite3_column_int(statement, 0))
            }
            return 0
        } else {
            return try count(table: "documents")
        }
    }

    public func getLastDocuments(limit: Int) throws -> [(id: String, sourcePath: String, createdAt: Date, indexedAt: Date)] {
        let sql = "SELECT id, source_path, created_at, indexed_at FROM documents ORDER BY indexed_at DESC LIMIT ?"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(limit))

        var results: [(id: String, sourcePath: String, createdAt: Date, indexedAt: Date)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(statement, 0))
            let path = String(cString: sqlite3_column_text(statement, 1))
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            let indexedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            results.append((id, path, createdAt, indexedAt))
        }
        return results
    }

    public func getBadFiles(limit: Int) throws -> [(path: String, mtime: Date, error: String, lastSeenAt: Date)] {
        let sql = "SELECT path, mtime, error, last_seen_at FROM bad_files ORDER BY last_seen_at DESC LIMIT ?"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(limit))

        var results: [(path: String, mtime: Date, error: String, lastSeenAt: Date)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let path = String(cString: sqlite3_column_text(statement, 0))
            let mtime = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            let error = String(cString: sqlite3_column_text(statement, 2))
            let lastSeen = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            results.append((path, mtime, error, lastSeen))
        }
        return results
    }

    private func count(table: String) throws -> Int {
        let query = "SELECT COUNT(*) FROM \(table)"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        if sqlite3_step(statement) == SQLITE_ROW {
            return Int(sqlite3_column_int(statement, 0))
        }
        return 0
    }

    // MARK: - Helper Methods

    @discardableResult
    private func execute(_ sql: String, parameters: [Any] = []) throws -> Int {
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        for (index, param) in parameters.enumerated() {
            let bindIndex = Int32(index + 1)
            switch param {
            case let value as String:
                sqlite3_bind_text(statement, bindIndex, value, -1, SQLITE_TRANSIENT)
            case let value as Int:
                sqlite3_bind_int(statement, bindIndex, Int32(value))
            case let value as Double:
                sqlite3_bind_double(statement, bindIndex, value)
            case let value as Data:
                _ = value.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, bindIndex, bytes.baseAddress, Int32(value.count), SQLITE_TRANSIENT)
                }
            case is NSNull:
                sqlite3_bind_null(statement, bindIndex)
            default:
                sqlite3_bind_null(statement, bindIndex)
            }
        }

        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_DONE || stepResult == SQLITE_ROW else {
            throw SQLiteError.executeError(String(cString: sqlite3_errmsg(db)))
        }

        return Int(sqlite3_changes(db))
    }
}

// MARK: - Supporting Types

public struct DatabaseStatistics {
    public let documentCount: Int
    public let chunkCount: Int
    public let embeddingCount: Int
    public let savedNoteCount: Int
    public let conceptCount: Int
}

public enum SQLiteError: LocalizedError {
    case cannotOpen(String)
    case prepareError(String)
    case executeError(String)

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let path):
            return "Cannot open database at: \(path)"
        case .prepareError(let message):
            return "Failed to prepare statement: \(message)"
        case .executeError(let message):
            return "Failed to execute statement: \(message)"
        }
    }
}

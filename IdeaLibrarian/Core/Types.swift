import Foundation

// MARK: - Document Types

public struct Document: Codable, Identifiable {
    public let id: String
    public let sourceType: SourceType
    public let sourcePath: String
    public let worldId: String?
    public let evolutionRunId: String?
    public let createdAt: Date
    public let indexedAt: Date
    public let metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        sourceType: SourceType,
        sourcePath: String,
        worldId: String? = nil,
        evolutionRunId: String? = nil,
        createdAt: Date = Date(),
        indexedAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.sourceType = sourceType
        self.sourcePath = sourcePath
        self.worldId = worldId
        self.evolutionRunId = evolutionRunId
        self.createdAt = createdAt
        self.indexedAt = indexedAt
        self.metadata = metadata
    }
}

public enum SourceType: String, Codable {
    case jsonEpisode = "json_episode"
    case transcript = "transcript"
    case pdf = "pdf"
    case atlasNote = "atlas_note"
    case pythonSource = "python_source"
    case swiftSource  = "swift_source"
}

// MARK: - Chunk Types

public struct Chunk: Codable, Identifiable {
    public let id: String
    public let documentId: String
    public let chunkIndex: Int
    public let contentType: ContentType
    public let content: String
    public let tokenCount: Int

    public init(
        id: String = UUID().uuidString,
        documentId: String,
        chunkIndex: Int,
        contentType: ContentType,
        content: String,
        tokenCount: Int
    ) {
        self.id = id
        self.documentId = documentId
        self.chunkIndex = chunkIndex
        self.contentType = contentType
        self.content = content
        self.tokenCount = tokenCount
    }
}

public enum ContentType: String, Codable {
    case question = "question"
    case stage1 = "stage1"
    case stage2 = "stage2"
    case conclusion = "conclusion"
    case contradiction = "contradiction"
    case nextQuestion = "next_question"
    // Source code chunk types (Python + Swift)
    case importBlock   = "import_block"    // import/from statements
    case classDef      = "class_def"       // class / enum / protocol / actor declaration
    case functionDef   = "function_def"    // function / method / def
    case moduleCode    = "module_code"     // module-level code outside any def/class
    case structDef     = "struct_def"      // Swift struct declaration
    case extensionDef  = "extension_def"   // Swift extension declaration
}

// MARK: - Embedding Types

public struct Embedding: Codable {
    public let chunkId: String
    public let modelName: String
    public let embedding: [Float]
    public let createdAt: Date

    public init(
        chunkId: String,
        modelName: String,
        embedding: [Float],
        createdAt: Date = Date()
    ) {
        self.chunkId = chunkId
        self.modelName = modelName
        self.embedding = embedding
        self.createdAt = createdAt
    }
}

// MARK: - Corpus Browser Types

public enum CorpusChunkFilter: String, Codable, CaseIterable, Identifiable {
    case all = "all"
    case embeddedOnly = "embedded_only"
    case withoutEmbeddings = "without_embeddings"

    public var id: String { rawValue }
}

/// Lightweight row used by the corpus browser UI.
/// Avoids loading embedding vectors (BLOBs) and focuses on chunk text + minimal metadata.
public struct ChunkCorpusRow: Identifiable, Codable {
    public let chunkId: String
    public let documentId: String
    public let chunkIndex: Int
    public let contentType: ContentType
    public let tokenCount: Int
    public let content: String
    public let hasEmbedding: Bool
    public let embeddingModelName: String?
    public let embeddingCreatedAt: Date?

    public var id: String { chunkId }

    public init(
        chunkId: String,
        documentId: String,
        chunkIndex: Int,
        contentType: ContentType,
        tokenCount: Int,
        content: String,
        hasEmbedding: Bool,
        embeddingModelName: String?,
        embeddingCreatedAt: Date?
    ) {
        self.chunkId = chunkId
        self.documentId = documentId
        self.chunkIndex = chunkIndex
        self.contentType = contentType
        self.tokenCount = tokenCount
        self.content = content
        self.hasEmbedding = hasEmbedding
        self.embeddingModelName = embeddingModelName
        self.embeddingCreatedAt = embeddingCreatedAt
    }
}

// MARK: - AtlasNote Types

public struct AtlasNote: Codable, Identifiable {
    public let id: String
    public let query: String
    public let summary: String
    public let keyConcepts: [String]
    public let sourceChunkIds: [String]
    public let createdAt: Date
    public let retrievalBoost: Float

    public init(
        id: String = UUID().uuidString,
        query: String,
        summary: String,
        keyConcepts: [String],
        sourceChunkIds: [String],
        createdAt: Date = Date(),
        retrievalBoost: Float = 1.5
    ) {
        self.id = id
        self.query = query
        self.summary = summary
        self.keyConcepts = keyConcepts
        self.sourceChunkIds = sourceChunkIds
        self.createdAt = createdAt
        self.retrievalBoost = retrievalBoost
    }
}

// MARK: - Concept Graph Types

public struct Concept: Codable, Identifiable {
    public let id: String
    public let name: String
    public let definition: String?
    public let firstSeen: Date
    public let occurrenceCount: Int

    public init(
        id: String = UUID().uuidString,
        name: String,
        definition: String? = nil,
        firstSeen: Date = Date(),
        occurrenceCount: Int = 1
    ) {
        self.id = id
        self.name = name
        self.definition = definition
        self.firstSeen = firstSeen
        self.occurrenceCount = occurrenceCount
    }
}

public struct ConceptRelation: Codable, Identifiable {
    public let id: String
    public let sourceConceptId: String
    public let targetConceptId: String
    public let relationType: RelationType
    public let evidenceChunkId: String?
    public let confidence: Float
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        sourceConceptId: String,
        targetConceptId: String,
        relationType: RelationType,
        evidenceChunkId: String? = nil,
        confidence: Float = 1.0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sourceConceptId = sourceConceptId
        self.targetConceptId = targetConceptId
        self.relationType = relationType
        self.evidenceChunkId = evidenceChunkId
        self.confidence = confidence
        self.createdAt = createdAt
    }
}

public enum RelationType: String, Codable {
    case coOccurrence = "co_occurrence"
    case supports = "supports"
    case contradicts = "contradicts"
    case extends = "extends"
    case derives = "derives"
}

// MARK: - Chat History Types

public struct Conversation: Codable, Identifiable {
    public let id: String
    public let title: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ChatMessage: Codable, Identifiable {
    public let id: String
    public let conversationId: String
    public let role: MessageRole
    public let content: String
    public let sourceChunks: [String]
    public let ccrScore: Float?
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        conversationId: String,
        role: MessageRole,
        content: String,
        sourceChunks: [String] = [],
        ccrScore: Float? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationId = conversationId
        self.role = role
        self.content = content
        self.sourceChunks = sourceChunks
        self.ccrScore = ccrScore
        self.createdAt = createdAt
    }
}

public enum MessageRole: String, Codable {
    case user = "user"
    case assistant = "assistant"
    case system = "system"
}

// MARK: - Retrieval Types

public struct RetrievalResult: Identifiable {
    public let id: String
    public let chunk: Chunk
    public let document: Document
    public let bm25Score: Float
    public let cosineScore: Float
    public let recencyScore: Float
    public let priorityBoost: Float
    public let hybridScore: Float

    public init(
        id: String = UUID().uuidString,
        chunk: Chunk,
        document: Document,
        bm25Score: Float,
        cosineScore: Float,
        recencyScore: Float,
        priorityBoost: Float,
        hybridScore: Float
    ) {
        self.id = id
        self.chunk = chunk
        self.document = document
        self.bm25Score = bm25Score
        self.cosineScore = cosineScore
        self.recencyScore = recencyScore
        self.priorityBoost = priorityBoost
        self.hybridScore = hybridScore
    }
}

public struct RetrievalContext {
    public let query: String
    public let results: [RetrievalResult]
    public let totalTokens: Int
    public let retrievalTime: TimeInterval

    public init(
        query: String,
        results: [RetrievalResult],
        totalTokens: Int,
        retrievalTime: TimeInterval
    ) {
        self.query = query
        self.results = results
        self.totalTokens = totalTokens
        self.retrievalTime = retrievalTime
    }
}

// MARK: - Query Result Types

public struct QueryResult {
    public let response: String
    public let context: RetrievalContext
    public let ccrScore: Float
    public let processingTime: TimeInterval
    public let showSources: Bool
    public let fromConceptCache: Bool

    public init(
        response: String,
        context: RetrievalContext,
        ccrScore: Float,
        processingTime: TimeInterval,
        showSources: Bool = true,
        fromConceptCache: Bool = false
    ) {
        self.response = response
        self.context = context
        self.ccrScore = ccrScore
        self.processingTime = processingTime
        self.showSources = showSources
        self.fromConceptCache = fromConceptCache
    }
}

// MARK: - Indexing Types

public struct IndexProgress {
    public let total: Int
    public let indexed: Int
    public let currentFile: String?
    public let isIndexing: Bool
    public let error: Error?

    public var progress: Float {
        guard total > 0 else { return 0 }
        return Float(indexed) / Float(total)
    }

    public init(
        total: Int,
        indexed: Int,
        currentFile: String? = nil,
        isIndexing: Bool,
        error: Error? = nil
    ) {
        self.total = total
        self.indexed = indexed
        self.currentFile = currentFile
        self.isIndexing = isIndexing
        self.error = error
    }
}

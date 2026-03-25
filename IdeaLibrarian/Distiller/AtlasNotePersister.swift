import Foundation

public class AtlasNotePersister {
    private let store: SQLiteStore

    public init(store: SQLiteStore) {
        self.store = store
    }

    public func persist(_ note: AtlasNote) throws -> Bool {
        if try store.atlasNoteExists(query: note.query, sourceChunkIds: note.sourceChunkIds) {
            return false
        }

        let document = Document(
            id: note.id,
            sourceType: .atlasNote,
            sourcePath: "atlas_note://\(note.id)",
            createdAt: note.createdAt,
            indexedAt: note.createdAt,
            metadata: ["query": note.query]
        )

        let chunk = Chunk(
            id: "note_chunk_\(note.id)",
            documentId: note.id,
            chunkIndex: 0,
            contentType: .conclusion,
            content: note.summary,
            tokenCount: estimateTokens(note.summary)
        )

        try store.beginTransaction()
        do {
            try store.insertDocument(document)
            try store.insertChunks([chunk], inTransaction: false)
            try store.insertAtlasNote(note)
            try store.commitTransaction()
            return true
        } catch {
            try? store.rollbackTransaction()
            throw error
        }
    }

    private func estimateTokens(_ text: String) -> Int {
        return max(1, text.count / 4)
    }
}

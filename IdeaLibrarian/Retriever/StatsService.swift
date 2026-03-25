import Foundation

/// Service for querying corpus statistics
/// Provides mentions count, by-folder breakdown, and top documents
public class StatsService {
    private let store: SQLiteStore

    public struct CorpusStats {
        public let term: String
        public let totalMentions: Int
        public let mentionsByFolder: [String: Int]
        public let topDocuments: [(docId: String, path: String, count: Int)]
        public let queryTime: TimeInterval

        public init(
            term: String,
            totalMentions: Int,
            mentionsByFolder: [String: Int],
            topDocuments: [(docId: String, path: String, count: Int)],
            queryTime: TimeInterval
        ) {
            self.term = term
            self.totalMentions = totalMentions
            self.mentionsByFolder = mentionsByFolder
            self.topDocuments = topDocuments
            self.queryTime = queryTime
        }
    }

    public init(store: SQLiteStore) {
        self.store = store
    }

    /// Get corpus statistics for a query term
    /// - Returns: CorpusStats with mentions total, by-folder, and top documents
    public func getStats(for term: String) -> CorpusStats? {
        let startTime = Date()

        do {
            // Query FTS index for mentions
            let mentionsByDocChunk = try getTermMentions(term: term)

            // Group by folder
            var mentionsByFolder: [String: Int] = [:]

            var docMentionMap: [String: (path: String, count: Int)] = [:]

            for (docId, chunkCount) in mentionsByDocChunk {
                if let doc = try store.getDocument(id: docId) {
                    let folder = extractFolder(from: doc.sourcePath) ?? "root"
                    mentionsByFolder[folder, default: 0] += chunkCount

                    docMentionMap[docId] = (doc.sourcePath, chunkCount)
                }
            }

            // Top documents
            let topDocs = docMentionMap
                .sorted { $0.value.count > $1.value.count }
                .prefix(5)
                .map { (docId: $0.key, path: $0.value.path, count: $0.value.count) }

            let totalMentions = mentionsByFolder.values.reduce(0, +)
            let queryTime = Date().timeIntervalSince(startTime)

            return CorpusStats(
                term: term,
                totalMentions: totalMentions,
                mentionsByFolder: mentionsByFolder,
                topDocuments: Array(topDocs),
                queryTime: queryTime
            )
        } catch {
            print("[StatsService] Error getting stats for '\(term)': \(error)")
            return nil
        }
    }

    /// Get mention counts for multiple terms
    public func getStatsMultiple(for terms: [String]) -> [String: CorpusStats] {
        var results: [String: CorpusStats] = [:]

        for term in terms {
            if let stats = getStats(for: term) {
                results[term] = stats
            }
        }

        return results
    }

    /// Get FTS search results for a term
    /// Returns dictionary mapping docId → chunk count
    private func getTermMentions(term: String) throws -> [String: Int] {
        var docMentionMap: [String: Int] = [:]

        // Use FTS search to find matching chunks
        let chunkIds = try store.searchChunks(query: term, limit: 1000)

        for chunkId in chunkIds {
            if let chunk = try store.getChunk(id: chunkId) {
                docMentionMap[chunk.documentId, default: 0] += 1
            }
        }

        return docMentionMap
    }

    /// Extract folder name from document path
    private func extractFolder(from path: String) -> String? {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        if components.count >= 2 {
            return components[components.count - 2]
        }
        return nil
    }

    /// Format stats as a human-readable summary
    public static func formatSummary(_ stats: CorpusStats) -> String {
        var summary = "Based on \(stats.totalMentions) mentions of '\(stats.term)' across corpus:\n"

        for (folder, count) in stats.mentionsByFolder.sorted(by: { $0.value > $1.value }) {
            if count > 0 {
                summary += "  • \(folder): \(count) mentions\n"
            }
        }

        if !stats.topDocuments.isEmpty {
            summary += "\nTop sources:\n"
            for (idx, doc) in stats.topDocuments.prefix(3).enumerated() {
                summary += "  \(idx + 1). \(doc.path) (\(doc.count) mentions)\n"
            }
        }

        return summary
    }
}

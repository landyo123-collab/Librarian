import Foundation

public class ContextAssembler {
    private let tokenBudgetManager: TokenBudgetManager

    public init(tokenBudgetManager: TokenBudgetManager) {
        self.tokenBudgetManager = tokenBudgetManager
    }

    public func build(
        query: String,
        results: [RetrievalResult],
        tokenBudget: Int
    ) -> RetrievalContext {
        let startTime = Date()

        // Select chunks within token budget
        let selectedResults = tokenBudgetManager.selectChunks(
            results: results,
            budget: tokenBudget
        )

        // Calculate total tokens
        let totalTokens = selectedResults.reduce(0) { $0 + $1.chunk.tokenCount }

        let retrievalTime = Date().timeIntervalSince(startTime)

        return RetrievalContext(
            query: query,
            results: selectedResults,
            totalTokens: totalTokens,
            retrievalTime: retrievalTime
        )
    }

    public func formatContext(_ context: RetrievalContext, conceptNote: String? = nil) -> String {
        var formatted = "# Retrieved Context\n\n"
        formatted += "Query: \(context.query)\n\n"
        formatted += "---\n\n"

        if let note = conceptNote {
            formatted += "## Internal Memory\n\n"
            formatted += note
            formatted += "\n\n---\n\n"
        }

        if context.results.isEmpty {
            if conceptNote == nil {
                formatted += "No sources retrieved.\n\n---\n\n"
            }
            return formatted
        }

        for (index, result) in context.results.enumerated() {
            formatted += "## Source \(index + 1)\n\n"
            formatted += chunkHeader(result)
            formatted += result.chunk.content
            formatted += "\n\n---\n\n"
        }

        return formatted
    }

    // MARK: - Conversational Context Formatting

    /// Format full conversational context with history, notes, and evidence
    public func formatConversationalContext(
        query: String,
        chatHistory: [ChatMessage],
        atlasNotes: [AtlasNote],
        retrievalResults: [RetrievalResult],
        conceptNote: String? = nil
    ) -> String {
        var formatted = ""

        // Section 1: Conversation History (if any)
        if !chatHistory.isEmpty {
            formatted += "# CONVERSATION SO FAR\n\n"
            for message in chatHistory {
                let role = message.role == .user ? "User" : "Assistant"
                // Truncate long messages to save tokens
                let content = message.content.count > 500
                    ? String(message.content.prefix(500)) + "..."
                    : message.content
                formatted += "**\(role):** \(content)\n\n"
            }
            formatted += "---\n\n"
        }

        // Section 2: Internal Memory (distilled notes from earlier queries)
        if !atlasNotes.isEmpty || conceptNote != nil {
            formatted += "# INTERNAL MEMORY\n\n"
            formatted += "*Distilled notes from previous queries:*\n\n"

            if let note = conceptNote {
                formatted += "**Cached Definition:**\n\(note)\n\n"
            }

            for (index, note) in atlasNotes.prefix(5).enumerated() {
                formatted += "**Memory \(index + 1)** (from: \"\(note.query)\")\n"
                // Truncate long summaries
                let summary = note.summary.count > 400
                    ? String(note.summary.prefix(400)) + "..."
                    : note.summary
                formatted += summary
                if !note.keyConcepts.isEmpty {
                    formatted += "\n*Key concepts:* \(note.keyConcepts.prefix(5).joined(separator: ", "))"
                }
                formatted += "\n\n"
            }
            formatted += "---\n\n"
        }

        // Section 3: Supporting Evidence (retrieved chunks)
        if !retrievalResults.isEmpty {
            formatted += "# SUPPORTING EVIDENCE\n\n"
            formatted += "*These are raw passages from the knowledge base:*\n\n"

            let evidenceCount = retrievalResults.count
            let fullTextCount: Int
            let excerptCharLimit: Int

            switch evidenceCount {
            case 0...20:
                fullTextCount = evidenceCount
                excerptCharLimit = 900
            case 21...50:
                fullTextCount = 20
                excerptCharLimit = 900
            default:
                fullTextCount = 12
                excerptCharLimit = 700
            }

            if evidenceCount > fullTextCount {
                formatted += "*Note: Sources after \(fullTextCount) are truncated excerpts to stay within context limits.*\n\n"
            }

            for (index, result) in retrievalResults.enumerated() {
                formatted += "## Source \(index + 1)\n\n"
                formatted += chunkHeader(result)
                if index < fullTextCount {
                    formatted += result.chunk.content
                } else {
                    formatted += truncate(result.chunk.content, maxChars: excerptCharLimit)
                }
                formatted += "\n\n---\n\n"
            }
        } else if atlasNotes.isEmpty && conceptNote == nil {
            formatted += "# CONTEXT\n\nNo sources or memories retrieved for this query.\n\n---\n\n"
        }

        // Section 4: Current Question
        formatted += "# CURRENT QUESTION\n\n"
        formatted += query
        formatted += "\n"

        return formatted
    }

    /// Build a rich chunk header for display, with extra context for source code files (Python + Swift)
    private func chunkHeader(_ result: RetrievalResult) -> String {
        let docName = result.document.sourcePath.components(separatedBy: "/").last ?? "Unknown"
        let contentType = result.chunk.contentType.rawValue

        if result.document.sourceType == .pythonSource || result.document.sourceType == .swiftSource {
            let project = result.document.metadata["project"] ?? "Unknown"
            let module  = result.document.metadata["module"]  ?? docName
            return "**Document:** \(docName)  |  **Project:** \(project)  |  **Module:** \(module)  |  **Type:** \(contentType)\n\n"
        }

        return "**Document:** \(docName)\n**Type:** \(contentType)\n**Created:** \(formatDate(result.document.createdAt))\n\n"
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func truncate(_ text: String, maxChars: Int) -> String {
        guard maxChars > 0 else { return "" }
        guard text.count > maxChars else { return text }
        let index = text.index(text.startIndex, offsetBy: maxChars)
        var truncated = String(text[..<index])
        if let lastSpace = truncated.lastIndex(of: " ") {
            truncated = String(truncated[..<lastSpace])
        }
        return truncated + "..."
    }
}

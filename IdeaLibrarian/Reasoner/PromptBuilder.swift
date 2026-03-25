import Foundation

public class PromptBuilder {
    public init() {}

    public func buildSystemPrompt(
        policy: AssistantPolicy,
        citeRequested: Bool,
        hasSources: Bool
    ) -> String {
        switch policy {
        case .chat:
            if citeRequested && hasSources {
                return """
                You are Librarian, a local research assistant.
                You can only use the provided context.

                Rules:
                1. Do not use outside knowledge.
                2. If context is missing, say: "I don't have that in the indexed files."
                3. Cite claims with [Source N].
                """
            }
            if hasSources {
                return """
                You are Librarian, a local research assistant.
                You can only use the provided context.

                Rules:
                1. Do not use outside knowledge.
                2. If context is missing, say: "I don't have that in the indexed files."
                3. Keep the answer natural and concise.
                """
            }
            return """
            You are Librarian, a local research assistant.
            No context was retrieved for this query.
            Respond with: "I don't have that in the indexed files."
            """
        case .librarian:
            return """
            You are Librarian, a local-first evidence assistant.
            Use only the provided context and cite every substantive claim with [Source N].
            If context is missing, say: "I don't have that in the indexed files."
            """
        }
    }

    public func buildUserPrompt(
        query: String,
        context: String,
        policy: AssistantPolicy,
        citeRequested: Bool,
        includeNoteInstruction: Bool = false
    ) -> String {
        switch policy {
        case .chat:
            if citeRequested {
                return """
                # Query
                \(query)

                # Context
                \(context)

                Answer using only this context.
                - Cite with [Source N]
                - If missing, say: "I don't have that in the indexed files."
                """
            }

            let base = """
            # Query
            \(query)

            # Context
            \(context)

            Answer using only this context.
            - If missing, say: "I don't have that in the indexed files."
            """

            if includeNoteInstruction {
                return base + "\n\n---\n[INTERNAL: On a final line output exactly: NOTE: <1-2 sentence summary from the context>]"
            }
            return base
        case .librarian:
            return """
            # Query
            \(query)

            # Context
            \(context)

            Answer using only this context.
            - Cite every substantive claim with [Source N]
            - If missing, say: "I don't have that in the indexed files."
            """
        }
    }

    public func buildMessages(
        query: String,
        context: String,
        policy: AssistantPolicy,
        citeRequested: Bool,
        hasSources: Bool,
        includeNoteInstruction: Bool = false
    ) -> [ChatCompletionMessage] {
        return [
            ChatCompletionMessage(role: "system", content: buildSystemPrompt(policy: policy, citeRequested: citeRequested, hasSources: hasSources)),
            ChatCompletionMessage(role: "user", content: buildUserPrompt(query: query, context: context, policy: policy, citeRequested: citeRequested, includeNoteInstruction: includeNoteInstruction))
        ]
    }

    public func buildConversationalSystemPrompt(
        outputFormat: ConversationalOutputFormat,
        hasHistory: Bool,
        hasNotes: Bool,
        hasEvidence: Bool,
        hasCodeSources: Bool = false,
        isDefinitional: Bool = false
    ) -> String {
        var prompt = """
        You are Librarian, a local-first assistant.
        Use only the supplied context and retrieved evidence.
        If evidence is missing, say: "I don't have that in the indexed files."
        """

        if hasHistory {
            prompt += """

            Conversation context is provided. Maintain continuity with recent turns.
            """
        }

        if hasNotes {
            prompt += """

            Internal distilled notes are provided. Use them as supporting memory.
            """
        }

        if hasEvidence {
            prompt += """

            Supporting evidence is provided. Keep all claims grounded in that evidence.
            """
        }

        if hasCodeSources {
            prompt += """

            Some evidence is source code.
            - Name function/type and file when discussing code.
            - Use fenced code blocks with language tags for snippets.
            - Do not infer behavior not shown in the provided code.
            """
        }

        switch outputFormat {
        case .conversational:
            prompt += """

            Output style:
            - Natural and concise.
            - No explicit citations in this mode.
            """
        case .synthesis:
            prompt += """

            Output format (required):
            ## THREADS
            ## CONNECTIONS
            ## UNCERTAINTIES
            ## PROPOSED NEXT STEP
            ## NOTE TO SAVE
            """
        case .citation:
            prompt += """

            Output style:
            - Cite with [Source N].
            - Every substantive claim must include a citation.
            """
        }

        if isDefinitional {
            prompt += """

            Concept caching:
            End with: NOTE: <1-2 sentence definition from context>
            """
        }

        return prompt
    }

    public func buildConversationalMessages(
        context: String,
        outputFormat: ConversationalOutputFormat,
        hasHistory: Bool,
        hasNotes: Bool,
        hasEvidence: Bool,
        hasCodeSources: Bool = false,
        isDefinitional: Bool = false
    ) -> [ChatCompletionMessage] {
        let systemPrompt = buildConversationalSystemPrompt(
            outputFormat: outputFormat,
            hasHistory: hasHistory,
            hasNotes: hasNotes,
            hasEvidence: hasEvidence,
            hasCodeSources: hasCodeSources,
            isDefinitional: isDefinitional
        )

        let userPrompt = """
        \(context)

        Respond using only the information above.
        If information is missing, say: "I don't have that in the indexed files."
        """

        return [
            ChatCompletionMessage(role: "system", content: systemPrompt),
            ChatCompletionMessage(role: "user", content: userPrompt)
        ]
    }

    public func buildMiniSynthesisMessages(
        query: String,
        originalSources: [RetrievalResult],
        additionalSources: [RetrievalResult],
        deepSeekDraft: String
    ) -> [ChatCompletionMessage] {
        let systemPrompt = """
        You are Librarian, the final synthesis layer.
        You may use only the provided draft and sources.
        Improve the draft by integrating additional evidence and clarifying cross-source links.
        """

        var userContent = "# Query\n\(query)\n\n"

        if !originalSources.isEmpty {
            userContent += "# Original Evidence (\(originalSources.count) sources)\n"
            for (i, result) in originalSources.enumerated() {
                let docName = result.document.sourcePath.components(separatedBy: "/").last ?? "Unknown"
                let snippet = String(result.chunk.content.prefix(400))
                userContent += "**[Source \(i + 1)] \(docName):** \(snippet)\n\n"
            }
            userContent += "---\n\n"
        }

        if !additionalSources.isEmpty {
            userContent += "# Additional Evidence\n"
            for (i, result) in additionalSources.enumerated() {
                let docName = result.document.sourcePath.components(separatedBy: "/").last ?? "Unknown"
                userContent += "**[Additional \(i + 1)] \(docName):**\n\(result.chunk.content)\n\n"
            }
            userContent += "---\n\n"
        }

        userContent += "# Draft Analysis\n\(deepSeekDraft)\n\n"
        userContent += "Produce a final answer that is grounded in the provided evidence."

        return [
            ChatCompletionMessage(role: "system", content: systemPrompt),
            ChatCompletionMessage(role: "user", content: userContent)
        ]
    }
}

public enum ConversationalOutputFormat {
    case conversational
    case synthesis
    case citation
}

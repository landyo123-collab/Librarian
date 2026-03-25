import XCTest
@testable import IdeaLibrarianCore

final class RetrievalLimitsTests: XCTestCase {
    func testDefaultTopKIs100() {
        let config = Configuration(deepSeekAPIKey: "test", openAIAPIKey: "test")
        XCTAssertEqual(config.topK, 100)
        XCTAssertEqual(config.maxTopK, 100)
    }

    func testSynthesisPlanFinalKUsesTopK() {
        let config = Configuration(
            deepSeekAPIKey: "test",
            openAIAPIKey: "test",
            triggerLexiconPath: "/nonexistent",
            canonTermsPath: "/nonexistent"
        )
        let planner = ExecutionPlanner(config: config)
        let plan = planner.buildPlan(
            query: "Broad topic",
            intent: "general",
            frameworkDetected: true,
            citeRequested: false,
            conversationId: "test"
        )
        XCTAssertEqual(plan.finalK, 100)
        XCTAssertGreaterThanOrEqual(plan.initialK, plan.finalK)
    }

    func testConversationalContextTruncatesAfterThreshold() {
        let assembler = ContextAssembler(tokenBudgetManager: TokenBudgetManager())

        let doc = Document(
            sourceType: .transcript,
            sourcePath: "/tmp/doc.txt",
            createdAt: Date(timeIntervalSince1970: 0),
            indexedAt: Date(timeIntervalSince1970: 0)
        )

        let shortContent = String(repeating: "A", count: 200)
        let longContentWithMarker = String(repeating: "B", count: 900) + "TAIL_MARKER_SHOULD_NOT_APPEAR"

        var results: [RetrievalResult] = []
        results.reserveCapacity(60)

        for index in 0..<60 {
            let content = index < 12 ? shortContent : longContentWithMarker
            let chunk = Chunk(
                documentId: doc.id,
                chunkIndex: index,
                contentType: .stage1,
                content: content,
                tokenCount: max(1, content.count / 4)
            )
            results.append(
                RetrievalResult(
                    chunk: chunk,
                    document: doc,
                    bm25Score: 1,
                    cosineScore: 0,
                    recencyScore: 0,
                    priorityBoost: 0,
                    hybridScore: Float(100 - index)
                )
            )
        }

        let text = assembler.formatConversationalContext(
            query: "q",
            chatHistory: [],
            atlasNotes: [],
            retrievalResults: results,
            conceptNote: nil
        )

        XCTAssertTrue(
            text.contains("*Note: Sources after 12 are truncated excerpts"),
            "Expected truncation note when evidenceCount > 50"
        )
        XCTAssertFalse(
            text.contains("TAIL_MARKER_SHOULD_NOT_APPEAR"),
            "Expected long evidence to be truncated before marker"
        )
    }
}


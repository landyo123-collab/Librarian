import Foundation

public enum AssistantPolicy: String, Codable {
    case chat
    case librarian
}

/// Phase 10: Answer style configuration
public enum AnswerStyle: String, Codable {
    case natural                    // No visible citations, conversational tone
    case groundedWithCitations      // Explicit citations, formal tone
}

public struct Configuration {
    // MARK: - API Configuration
    public let deepSeekAPIKey: String
    public let openAIAPIKey: String

    // MARK: - .env File Loader

    private static func loadDotEnv() -> [String: String] {
        let fileManager = FileManager.default

        var candidatePaths: [String] = []
        if let explicit = ProcessInfo.processInfo.environment["LIBRARIAN_ENV_FILE"], !explicit.isEmpty {
            candidatePaths.append(explicit)
        }

        let cwdPath = fileManager.currentDirectoryPath
        candidatePaths.append(URL(fileURLWithPath: cwdPath, isDirectory: true).appendingPathComponent(".env").path)
        candidatePaths.append(fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".env").path)
        candidatePaths.append(fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".config/librarian/.env").path)

        var seen: Set<String> = []
        for path in candidatePaths where seen.insert(path).inserted {
            guard fileManager.fileExists(atPath: path),
                  let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                continue
            }
            return parseDotEnv(contents)
        }

        return [:]
    }

    private static func parseDotEnv(_ contents: String) -> [String: String] {
        var vars: [String: String] = [:]
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }

            let key = String(trimmed[trimmed.startIndex..<eqIndex]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)

            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }

            if !key.isEmpty {
                vars[key] = value
            }
        }
        return vars
    }

    public static func canonicalUserLibraryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Librarian", isDirectory: true)
            .appendingPathComponent("UserLibrary", isDirectory: true)
            .standardizedFileURL
    }

    private static func defaultKnowledgePath() -> String {
        canonicalUserLibraryURL().path
    }

    private static func defaultTriggerLexiconPath() -> String {
        let fileManager = FileManager.default

        if let explicit = ProcessInfo.processInfo.environment["LIBRARIAN_TRIGGER_PATH"], !explicit.isEmpty,
           fileManager.fileExists(atPath: explicit) {
            return explicit
        }

        for root in candidateRoots() {
            let candidate = root
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("triggers", isDirectory: true)
                .appendingPathComponent("triggers-generated.json", isDirectory: false)
                .path

            if fileManager.fileExists(atPath: candidate) {
                return candidate
            }
        }

        return ""
    }

    private static func candidateRoots() -> [URL] {
        var roots: [URL] = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        ]

        if let executableURL = Bundle.main.executableURL {
            var cursor = executableURL.deletingLastPathComponent()
            for _ in 0..<8 {
                roots.append(cursor)
                cursor = cursor.deletingLastPathComponent()
            }
        } else if let arg0 = CommandLine.arguments.first {
            var cursor = URL(fileURLWithPath: arg0).deletingLastPathComponent()
            for _ in 0..<8 {
                roots.append(cursor)
                cursor = cursor.deletingLastPathComponent()
            }
        }

        var seen: Set<String> = []
        var deduped: [URL] = []
        for root in roots {
            let normalized = root.standardizedFileURL.path
            if seen.insert(normalized).inserted {
                deduped.append(root)
            }
        }
        return deduped
    }

    // MARK: - Database Configuration
    public let databasePath: String

    // MARK: - Indexing Configuration
    public let corpusPath: String
    public let chunkSize: Int
    public let batchSize: Int

    // MARK: - Retrieval Configuration
    public let topK: Int
    public let tokenBudget: Int
    public let maxChunksPerDocument: Int
    public let defaultPolicy: AssistantPolicy
    public let defaultTopKChat: Int
    public let defaultTopKLibrarian: Int
    public let maxTopK: Int
    public let enableSemanticRetrieval: Bool
    public let semanticOnlyIfLexicalWeak: Bool
    public let lexicalWeakThreshold: Float
    public let showSourcesInChat: Bool
    public let showCitationsInChat: Bool
    public let showSourcesInLibrarian: Bool
    public let showCitationsInLibrarian: Bool
    public let allowUserOverridePolicy: Bool

    // MARK: - Hybrid Scoring Weights
    public let alphaBM25: Float
    public let betaCosine: Float
    public let gammaRecency: Float
    public let notePriorityBoost: Float

    // MARK: - Reasoning Configuration
    public let deepSeekModel: String
    public let temperature: Float
    public let maxTokens: Int
    public let ccrThreshold: Float
    public let maxRetries: Int

    // MARK: - Embedding Configuration
    public let embeddingModel: String
    public let embeddingDimension: Int
    public let embeddingBatchSize: Int

    // MARK: - Phase 10: Query Decomposition
    public let enableQueryDecomposition: Bool
    public let maxSubqueries: Int
    public let minSubqueryLength: Int
    public let coverageBonus: Float

    // MARK: - Phase 10: Trigger-Based Retrieval & Answer Style
    public let enableTriggerLexicon: Bool
    public let triggerLexiconPath: String
    public let canonTermsPath: String
    public let answerStyle: AnswerStyle  // .natural (no citations) or .groundedWithCitations
    public let enableTriggerDebugLog: Bool
    public let folderPriorityWeights: [String: Float]
    public let enforceFolderPriorityDiversity: Bool

    // MARK: - Phase 11: GPT-5 mini Synthesis Layer
    public let enableMiniSynthesisLayer: Bool
    public let gptMiniModel: String
    public let maxSecondPassChunks: Int
    public let gptMiniMaxTokens: Int

    // MARK: - Timeouts
    public let apiRequestTimeout: TimeInterval
    public let apiResourceTimeout: TimeInterval

    public init(
        deepSeekAPIKey: String? = nil,
        openAIAPIKey: String? = nil,
        databasePath: String? = nil,
        corpusPath: String? = nil,
        chunkSize: Int = 512,
        batchSize: Int = 100,
        topK: Int = 100,
        tokenBudget: Int = 6000,
        maxChunksPerDocument: Int = 2,
        defaultPolicy: AssistantPolicy = .chat,
        defaultTopKChat: Int = 15,
        defaultTopKLibrarian: Int = 15,
        maxTopK: Int = 100,
        enableSemanticRetrieval: Bool = true,
        semanticOnlyIfLexicalWeak: Bool = true,
        lexicalWeakThreshold: Float = 0.6,
        showSourcesInChat: Bool = false,
        showCitationsInChat: Bool = false,
        showSourcesInLibrarian: Bool = true,
        showCitationsInLibrarian: Bool = true,
        allowUserOverridePolicy: Bool = true,
        alphaBM25: Float = 0.5,
        betaCosine: Float = 0.3,
        gammaRecency: Float = 0.2,
        notePriorityBoost: Float = 0.5,
        deepSeekModel: String = "deepseek-reasoner",
        temperature: Float = 0.7,
        maxTokens: Int = 8000,
        ccrThreshold: Float = 0.9,
        maxRetries: Int = 2,
        embeddingModel: String = "text-embedding-3-small",
        embeddingDimension: Int = 1536,
        embeddingBatchSize: Int = 100,
        enableQueryDecomposition: Bool = true,
        maxSubqueries: Int = 4,
        minSubqueryLength: Int = 12,
        coverageBonus: Float = 0.05,
        apiRequestTimeout: TimeInterval = 60,
        apiResourceTimeout: TimeInterval = 120,
        // Phase 11: GPT-5 mini synthesis layer
        enableMiniSynthesisLayer: Bool = true,
        gptMiniModel: String = "gpt-5-mini",
        maxSecondPassChunks: Int = 8,
        gptMiniMaxTokens: Int = 16000,
        // Phase 10 options
        enableTriggerLexicon: Bool = true,
        triggerLexiconPath: String = "",
        canonTermsPath: String = "",
        answerStyle: AnswerStyle = .natural,
        enableTriggerDebugLog: Bool = false,
        folderPriorityWeights: [String: Float] = [
            "projects": 1.3,
            "src": 1.2,
            "notes": 1.15,
            "docs": 1.1
        ],
        enforceFolderPriorityDiversity: Bool = true
    ) {
        // API keys: explicit param > env var > .env file
        let dotEnv = Configuration.loadDotEnv()
        self.deepSeekAPIKey = deepSeekAPIKey
            ?? ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]
            ?? dotEnv["DEEPSEEK_API_KEY"]
            ?? ""
        self.openAIAPIKey = openAIAPIKey
            ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
            ?? dotEnv["OPENAI_API_KEY"]
            ?? ""

        // Default database path in Application Support
        if let dbPath = databasePath {
            self.databasePath = dbPath
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let librarianDir = appSupport.appendingPathComponent("Librarian", isDirectory: true)
            try? FileManager.default.createDirectory(at: librarianDir, withIntermediateDirectories: true)
            self.databasePath = librarianDir.appendingPathComponent("librarian.db").path
        }

        // Canonical corpus path.
        self.corpusPath = corpusPath ?? Configuration.defaultKnowledgePath()

        self.chunkSize = chunkSize
        self.batchSize = batchSize
        self.topK = topK
        self.tokenBudget = tokenBudget
        self.maxChunksPerDocument = maxChunksPerDocument
        self.defaultPolicy = defaultPolicy
        self.defaultTopKChat = defaultTopKChat
        self.defaultTopKLibrarian = defaultTopKLibrarian
        self.maxTopK = maxTopK
        self.enableSemanticRetrieval = enableSemanticRetrieval
        self.semanticOnlyIfLexicalWeak = semanticOnlyIfLexicalWeak
        self.lexicalWeakThreshold = lexicalWeakThreshold
        self.showSourcesInChat = showSourcesInChat
        self.showCitationsInChat = showCitationsInChat
        self.showSourcesInLibrarian = showSourcesInLibrarian
        self.showCitationsInLibrarian = showCitationsInLibrarian
        self.allowUserOverridePolicy = allowUserOverridePolicy
        self.alphaBM25 = alphaBM25
        self.betaCosine = betaCosine
        self.gammaRecency = gammaRecency
        self.notePriorityBoost = notePriorityBoost
        self.deepSeekModel = deepSeekModel
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.ccrThreshold = ccrThreshold
        self.maxRetries = maxRetries
        self.embeddingModel = embeddingModel
        self.embeddingDimension = embeddingDimension
        self.embeddingBatchSize = embeddingBatchSize
        self.enableQueryDecomposition = enableQueryDecomposition
        self.maxSubqueries = maxSubqueries
        self.minSubqueryLength = minSubqueryLength
        self.coverageBonus = coverageBonus
        self.apiRequestTimeout = apiRequestTimeout
        self.apiResourceTimeout = apiResourceTimeout
        // Phase 10
        self.enableTriggerLexicon = enableTriggerLexicon
        if triggerLexiconPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.triggerLexiconPath = Configuration.defaultTriggerLexiconPath()
        } else {
            self.triggerLexiconPath = triggerLexiconPath
        }
        self.canonTermsPath = canonTermsPath
        self.answerStyle = answerStyle
        self.enableTriggerDebugLog = enableTriggerDebugLog
        self.folderPriorityWeights = folderPriorityWeights
        self.enforceFolderPriorityDiversity = enforceFolderPriorityDiversity
        // Phase 11
        self.enableMiniSynthesisLayer = enableMiniSynthesisLayer
        self.gptMiniModel = gptMiniModel
        self.maxSecondPassChunks = maxSecondPassChunks
        self.gptMiniMaxTokens = gptMiniMaxTokens
    }

    // MARK: - Validation

    public func validate() throws {
        if deepSeekAPIKey.isEmpty {
            throw ConfigurationError.missingAPIKey("DEEPSEEK_API_KEY environment variable not set")
        }
        if openAIAPIKey.isEmpty {
            throw ConfigurationError.missingAPIKey("OPENAI_API_KEY environment variable not set")
        }
        if !FileManager.default.fileExists(atPath: corpusPath) {
            throw ConfigurationError.invalidPath("Corpus path does not exist: \(corpusPath)")
        }
    }
}

public enum ConfigurationError: LocalizedError {
    case missingAPIKey(String)
    case invalidPath(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let message):
            return "Missing API Key: \(message)"
        case .invalidPath(let message):
            return "Invalid Path: \(message)"
        }
    }
}

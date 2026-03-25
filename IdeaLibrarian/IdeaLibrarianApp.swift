import SwiftUI
#if canImport(IdeaLibrarianCore)
import IdeaLibrarianCore
#endif

@main
struct IdeaLibrarianApp: App {
    let engine: AtlasEngine?
    let initError: String?
    let userLibraryPath: String

    init() {
        let args = ProcessInfo.processInfo.arguments
        let dbArg = value(after: "--db", in: args)
        let canonicalLibraryURL = Configuration.canonicalUserLibraryURL()

        do {
            try FileManager.default.createDirectory(at: canonicalLibraryURL, withIntermediateDirectories: true)

            if args.contains("--diagnose") {
                let diagConfig = Configuration(databasePath: dbArg, corpusPath: canonicalLibraryURL.path)
                DiagnosticsRunner.run(rootPath: canonicalLibraryURL.path, databasePath: diagConfig.databasePath)
                exit(0)
            }

            let policyArg = value(after: "--policy", in: args)?.lowercased()
            let overridePolicy = policyArg.flatMap { AssistantPolicy(rawValue: $0) }

            let baseConfig = Configuration(databasePath: dbArg, corpusPath: canonicalLibraryURL.path)
            let finalPolicy: AssistantPolicy = {
                if baseConfig.allowUserOverridePolicy, let overridePolicy = overridePolicy {
                    return overridePolicy
                }
                return baseConfig.defaultPolicy
            }()

            let config = Configuration(
                databasePath: baseConfig.databasePath,
                corpusPath: canonicalLibraryURL.path,
                defaultPolicy: finalPolicy,
                triggerLexiconPath: baseConfig.triggerLexiconPath,
                canonTermsPath: baseConfig.canonTermsPath
            )

            print("Policy: \(config.defaultPolicy.rawValue)")
            print("Corpus folder: \(canonicalLibraryURL.path)")
            print("DB path: \(config.databasePath)")
            print("Trigger lexicon: \(config.triggerLexiconPath.isEmpty ? "built-in defaults" : config.triggerLexiconPath)")
            print("Retrieval: semantic=\(config.enableSemanticRetrieval) semanticOnlyIfLexicalWeak=\(config.semanticOnlyIfLexicalWeak) lexicalWeakThreshold=\(config.lexicalWeakThreshold)")

            self.engine = try AtlasEngine(config: config)
            self.initError = nil
        } catch {
            self.engine = nil
            self.initError = "\(error)"
        }

        self.userLibraryPath = canonicalLibraryURL.path
    }

    var body: some Scene {
        WindowGroup("Librarian") {
            if let engine {
                ContentView(engine: engine, userLibraryPath: userLibraryPath)
            } else {
                Text("Failed to initialize Librarian.\n\n\(initError ?? "Unknown error")")
                    .padding()
                    .frame(minWidth: 500, minHeight: 300)
            }
        }
    }
}

private func value(after flag: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: flag) else { return nil }
    let next = args.index(after: index)
    if next < args.endIndex {
        return args[next]
    }
    return nil
}

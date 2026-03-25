import Foundation

/// Parses Swift source files (.swift) into Documents and Chunks.
///
/// Chunking strategy: split at top-level type declarations (class/struct/enum/protocol/actor/extension)
/// and at func/init declarations at both the top level and one indent level inside a type.
/// Import declarations are prepended to each type/function chunk as context preamble.
/// Access modifiers (public, private, static, override, @attributes, etc.) are handled
/// transparently — the parser looks for the keyword that matters (func, class, struct, …)
/// regardless of what comes before it on the same line.
public class SwiftFileParser {

    public init() {}

    // MARK: - Public Entry Point

    public func parse(fileURL: URL) throws -> (document: Document, chunks: [Chunk]) {
        let text = try readText(from: fileURL)
        let path = fileURL.path

        let projectName  = extractProjectName(from: path)
        let relativePath = extractRelativePath(from: path)
        let moduleName   = deriveModuleName(from: relativePath)

        let codeChunks    = chunkSwiftFile(text: text)
        let hasTypes      = codeChunks.contains { $0.contentType == .classDef || $0.contentType == .structDef || $0.contentType == .extensionDef }
        let hasFunctions  = codeChunks.contains { $0.contentType == .functionDef }

        let document = Document(
            sourceType: .swiftSource,
            sourcePath: path,
            metadata: [
                "language":      "swift",
                "project":       projectName,
                "relative_path": relativePath,
                "module":        moduleName,
                "has_types":     hasTypes     ? "true" : "false",
                "has_functions": hasFunctions ? "true" : "false"
            ]
        )

        // Re-index chunks so indexes are sequential after compactMap filtering
        var chunkIndex = 0
        let chunks: [Chunk] = codeChunks.compactMap { codeChunk in
            guard codeChunk.content.count > 50 else { return nil }
            let chunk = Chunk(
                documentId:  document.id,
                chunkIndex:  chunkIndex,
                contentType: codeChunk.contentType,
                content:     codeChunk.content,
                tokenCount:  max(1, codeChunk.content.count / 4)
            )
            chunkIndex += 1
            return chunk
        }

        return (document: document, chunks: chunks)
    }

    // MARK: - Text Reading

    private func readText(from url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else {
            throw SwiftParserError.unreadableFile(url.path)
        }
        // Swift source files are always UTF-8 per the language spec
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        throw SwiftParserError.unreadableFile(url.path)
    }

    // MARK: - Project Metadata Extraction

    /// Extracts the project name: first path component after "/projects/"
    /// e.g. ".../projects/MyApp/Sources/file.swift" → "MyApp"
    private func extractProjectName(from path: String) -> String {
        let components = path.components(separatedBy: "/")
        for (i, component) in components.enumerated() {
            if component == "projects" && i + 1 < components.count {
                let name = components[i + 1]
                return name.isEmpty ? "Unknown" : name
            }
        }
        return "Unknown"
    }

    /// Extracts the file path relative to the project root
    /// e.g. "/…/projects/MyApp/Sources/Core/Engine.swift" → "Sources/Core/Engine.swift"
    private func extractRelativePath(from path: String) -> String {
        let components = path.components(separatedBy: "/")
        for (i, component) in components.enumerated() {
            if component == "projects" && i + 2 < components.count {
                return components[(i + 2)...].joined(separator: "/")
            }
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// Derives a module-style name from the relative file path
    /// e.g. "Sources/Core/Engine.swift" → "Sources.Core.Engine"
    private func deriveModuleName(from relativePath: String) -> String {
        var module = relativePath
        if module.hasSuffix(".swift") {
            module = String(module.dropLast(6))
        }
        return module.replacingOccurrences(of: "/", with: ".")
    }

    // MARK: - Swift Code Chunking

    private struct CodeChunk {
        let contentType: ContentType
        let content: String
    }

    private func chunkSwiftFile(text: String) -> [CodeChunk] {
        let lines = text.components(separatedBy: "\n")
        var chunks: [CodeChunk] = []

        // ── Step 1: collect import block ───────────────────────────────────────
        // Swift files often begin with a copyright/file-header comment block,
        // then import statements. We skip blank lines and comment lines (// /* *)
        // until we find `import` lines, then stop collecting after the last one.
        var importLines: [String] = []
        for line in lines {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty
                || stripped.hasPrefix("//")
                || stripped.hasPrefix("/*")
                || stripped.hasPrefix("*") {
                continue
            }
            if stripped.hasPrefix("import ") {
                importLines.append(stripped)
            } else {
                break  // first non-import, non-comment line — done collecting
            }
        }

        let importText     = importLines.joined(separator: "\n")
        let importPreamble = importText.isEmpty ? "" : "// --- imports ---\n\(importText)\n\n"

        if !importText.isEmpty && importText.count > 20 {
            chunks.append(CodeChunk(contentType: .importBlock, content: importText))
        }

        // ── Step 2: compile regex patterns (once, before the line loop) ────────
        //
        // topTypeRE  — top-level type declarations at column 0
        //   Handles optional access modifiers / @attributes before the keyword:
        //   e.g. "public final class Foo", "@MainActor struct Bar", "extension Baz"
        //   Groups: (1) type keyword, (2) type name
        let topTypeRE = try? NSRegularExpression(
            pattern: "^(?:(?:@\\w+(?:\\([^)]*\\))?|\\w+)\\s+)*(class|struct|enum|protocol|actor|extension)\\s+(\\w+)")

        // topFuncRE  — top-level func/init at column 0 (with optional modifiers)
        //   e.g. "public func foo(", "static func bar(", "init(", "@discardableResult func baz("
        //   The final character class [\\w(] ensures we don't match `functional` etc.
        let topFuncRE = try? NSRegularExpression(
            pattern: "^(?:(?:@\\w+(?:\\([^)]*\\))?|\\w+)\\s+)*(?:func|init)\\s*[\\w(]")

        // methodRE   — func/init indented 1-4 spaces or 1 tab (method inside a type)
        //   e.g. "    public func foo(", "\tinit(", "    override func viewDidLoad("
        let methodRE = try? NSRegularExpression(
            pattern: "^[ \\t]{1,4}(?:(?:@\\w+(?:\\([^)]*\\))?|\\w+)\\s+)*(?:func|init)\\s*[\\w(]")

        // ── Step 3: state-machine over lines ───────────────────────────────────
        var currentLines: [String] = []
        var currentType:  ContentType = .moduleCode
        var currentParent: String?    = nil  // name of enclosing type, if any

        /// Flush accumulated lines as a completed chunk, prepending context preamble.
        func flush() {
            let raw = currentLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.count > 50 else { return }

            var preamble = ""
            switch currentType {
            case .functionDef:
                preamble = importPreamble
                if let parent = currentParent {
                    preamble += "// Type: \(parent)\n\n"
                }
            case .classDef, .structDef, .extensionDef:
                preamble = importPreamble
            default:
                break
            }

            let finalContent = preamble + raw
            appendSplitting(finalContent, type: currentType, into: &chunks)
        }

        for line in lines {
            let ns    = line as NSString
            let range = NSRange(location: 0, length: ns.length)

            if let match = topTypeRE?.firstMatch(in: line, range: range) {
                flush()
                currentLines  = [line]
                // Determine content type from the captured keyword (group 1)
                let keyword = extractGroup(match, in: line, group: 1)
                currentType   = contentTypeForSwiftKeyword(keyword)
                currentParent = extractGroup(match, in: line, group: 2)

            } else if topFuncRE?.firstMatch(in: line, range: range) != nil {
                flush()
                currentLines  = [line]
                currentType   = .functionDef
                currentParent = nil   // top-level function is outside any type

            } else if methodRE?.firstMatch(in: line, range: range) != nil {
                flush()
                currentLines  = [line]
                currentType   = .functionDef
                // currentParent intentionally preserved — method inherits parent type context

            } else {
                currentLines.append(line)
            }
        }
        flush()   // flush final accumulated chunk

        // ── Step 4: fallback for files with no detected structure ──────────────
        if chunks.filter({ $0.contentType != .importBlock }).isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count > 50 {
                appendSplitting(trimmed, type: .moduleCode, into: &chunks)
            }
        }

        return chunks
    }

    // MARK: - Helpers

    /// Maps a Swift type keyword to the appropriate ContentType.
    private func contentTypeForSwiftKeyword(_ keyword: String?) -> ContentType {
        switch keyword {
        case "struct":                         return .structDef
        case "extension":                      return .extensionDef
        case "class", "enum", "protocol",
             "actor", nil:                     return .classDef
        default:                               return .classDef
        }
    }

    /// Appends content as one or more chunks of at most 512 tokens (~2048 chars).
    private func appendSplitting(_ content: String, type: ContentType, into chunks: inout [CodeChunk]) {
        let maxChars = 512 * 4
        guard content.count > maxChars else {
            chunks.append(CodeChunk(contentType: type, content: content))
            return
        }
        var remaining = content
        while !remaining.isEmpty {
            let cutLen = min(maxChars, remaining.count)
            let cutEnd = remaining.index(remaining.startIndex, offsetBy: cutLen)
            chunks.append(CodeChunk(contentType: type, content: String(remaining[..<cutEnd])))
            remaining = String(remaining[cutEnd...])
        }
    }

    /// Extracts a capture group from an NSTextCheckingResult.
    private func extractGroup(_ match: NSTextCheckingResult, in string: String, group: Int) -> String? {
        guard match.numberOfRanges > group,
              let range = Range(match.range(at: group), in: string) else {
            return nil
        }
        return String(string[range])
    }
}

// MARK: - Errors

public enum SwiftParserError: LocalizedError {
    case unreadableFile(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableFile(let path):
            return "Cannot read Swift file: \(path)"
        }
    }
}

import Foundation

/// Parses Python source files (.py) into Documents and Chunks.
///
/// Chunking strategy: split at top-level class/def and first-level method (4-space indent)
/// boundaries, so each function or class header becomes a discrete retrieval unit.
/// Import declarations are prepended to each function/class chunk as context preamble.
public class PythonFileParser {

    public init() {}

    // MARK: - Public Entry Point

    public func parse(fileURL: URL) throws -> (document: Document, chunks: [Chunk]) {
        let text = try readText(from: fileURL)
        let path = fileURL.path

        let projectName  = extractProjectName(from: path)
        let relativePath = extractRelativePath(from: path)
        let moduleName   = deriveModuleName(from: relativePath)

        let codeChunks   = chunkPythonFile(text: text)
        let hasClasses   = codeChunks.contains { $0.contentType == .classDef }
        let hasFunctions = codeChunks.contains { $0.contentType == .functionDef }

        let document = Document(
            sourceType: .pythonSource,
            sourcePath: path,
            metadata: [
                "language":      "python",
                "project":       projectName,
                "relative_path": relativePath,
                "module":        moduleName,
                "has_classes":   hasClasses   ? "true" : "false",
                "has_functions": hasFunctions ? "true" : "false"
            ]
        )

        // Re-index chunks so indexes are sequential after compactMap filtering
        var chunkIndex = 0
        let chunks: [Chunk] = codeChunks.compactMap { codeChunk in
            guard codeChunk.content.count > 50 else { return nil }
            let chunk = Chunk(
                documentId:   document.id,
                chunkIndex:   chunkIndex,
                contentType:  codeChunk.contentType,
                content:      codeChunk.content,
                tokenCount:   max(1, codeChunk.content.count / 4)
            )
            chunkIndex += 1
            return chunk
        }

        return (document: document, chunks: chunks)
    }

    // MARK: - Text Reading

    private func readText(from url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else {
            throw PythonParserError.unreadableFile(url.path)
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        // Fallback for unusual encodings (rare in Python, but possible in legacy code)
        if let text = String(data: data, encoding: .isoLatin1) {
            return text
        }
        throw PythonParserError.unreadableFile(url.path)
    }

    // MARK: - Project Metadata Extraction

    /// Extracts the project name: first path component after "/projects/"
    /// e.g. ".../projects/MyProject/src/file.py" → "MyProject"
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
    /// e.g. "/…/projects/MyProject/src/core/engine.py" → "src/core/engine.py"
    private func extractRelativePath(from path: String) -> String {
        let components = path.components(separatedBy: "/")
        for (i, component) in components.enumerated() {
            if component == "projects" && i + 2 < components.count {
                return components[(i + 2)...].joined(separator: "/")
            }
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// Derives a Python module name from the relative file path
    /// e.g. "src/core/engine.py" → "src.core.engine"
    private func deriveModuleName(from relativePath: String) -> String {
        var module = relativePath
        if module.hasSuffix(".py") {
            module = String(module.dropLast(3))
        }
        return module.replacingOccurrences(of: "/", with: ".")
    }

    // MARK: - Python Code Chunking

    private struct CodeChunk {
        let contentType: ContentType
        let content: String
    }

    private func chunkPythonFile(text: String) -> [CodeChunk] {
        let lines = text.components(separatedBy: "\n")
        var chunks: [CodeChunk] = []

        // ── Step 1: collect import block from top of file ──────────────────────
        // Gather consecutive import/from lines before the first non-import code.
        var importLines: [String] = []
        for line in lines {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty || stripped.hasPrefix("#") { continue }
            if stripped.hasPrefix("import ") || stripped.hasPrefix("from ") {
                importLines.append(line)
            } else {
                break
            }
        }

        let importText     = importLines.joined(separator: "\n")
        let importPreamble = importText.isEmpty ? "" : "# --- imports ---\n\(importText)\n\n"

        if !importText.isEmpty && importText.count > 50 {
            chunks.append(CodeChunk(contentType: .importBlock, content: importText))
        }

        // ── Step 2: state-machine over lines ───────────────────────────────────
        // Compiled once; reused for every line.
        // topClassRE  matches "class Foo" at column 0
        // topFuncRE   matches "def foo"   at column 0
        // methodRE    matches "def foo"   indented 1-4 spaces or 1 tab (class method)
        let topClassRE = try? NSRegularExpression(pattern: "^class\\s+(\\w+)")
        let topFuncRE  = try? NSRegularExpression(pattern: "^def\\s+(\\w+)")
        let methodRE   = try? NSRegularExpression(pattern: "^[ \\t]{1,4}def\\s+(\\w+)")

        var currentLines: [String] = []
        var currentType:  ContentType = .moduleCode
        var currentClass: String?     = nil   // name of enclosing class, if any

        // Flush the accumulated lines as a chunk, prepending import/class context.
        func flush() {
            let raw = currentLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.count > 50 else { return }

            var preamble = ""
            switch currentType {
            case .functionDef:
                preamble = importPreamble
                if let cls = currentClass {
                    preamble += "# Class: \(cls)\n\n"
                }
            case .classDef:
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

            if topClassRE?.firstMatch(in: line, range: range) != nil {
                flush()
                currentLines = [line]
                currentType  = .classDef
                currentClass = extractFirstGroup(topClassRE, in: line)

            } else if topFuncRE?.firstMatch(in: line, range: range) != nil {
                flush()
                currentLines = [line]
                currentType  = .functionDef
                currentClass = nil   // top-level function is outside any class

            } else if methodRE?.firstMatch(in: line, range: range) != nil {
                flush()
                currentLines = [line]
                currentType  = .functionDef
                // currentClass intentionally preserved — method inherits parent class context

            } else {
                currentLines.append(line)
            }
        }
        flush()   // flush final accumulated chunk

        // ── Step 3: fallback for pure-script files ─────────────────────────────
        if chunks.filter({ $0.contentType != .importBlock }).isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count > 50 {
                appendSplitting(trimmed, type: .moduleCode, into: &chunks)
            }
        }

        return chunks
    }

    /// Appends `content` as one or more chunks of at most 512 tokens (~2048 chars).
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

    /// Extracts the first capture group from a regex match.
    private func extractFirstGroup(_ re: NSRegularExpression?, in string: String) -> String? {
        guard let re = re else { return nil }
        let range = NSRange(location: 0, length: (string as NSString).length)
        guard let match = re.firstMatch(in: string, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: string) else {
            return nil
        }
        return String(string[captureRange])
    }
}

// MARK: - Errors

public enum PythonParserError: LocalizedError {
    case emptyFile
    case unreadableFile(String)

    public var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "Python file is empty"
        case .unreadableFile(let path):
            return "Cannot read Python file: \(path)"
        }
    }
}

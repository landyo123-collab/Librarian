import Foundation

public struct DiagnosticsRunner {
    public struct FailureExample {
        public let path: String
        public let firstBytesHex: String
        public let fileSize: Int
        public let encodingGuess: String
        public let error: String
    }

    public static func run(rootPath: String, databasePath: String) {
        let rootURL = URL(fileURLWithPath: rootPath)
        let scanner = DocumentScanner()
        let parser = JSONEpisodeParser(chunkingStrategy: ChunkingStrategy())
        let store: SQLiteStore?
        do {
            store = try SQLiteStore(path: databasePath)
        } catch {
            print("Diagnostics: failed to open DB at \(databasePath): \(error)")
            store = nil
        }

        print("=== Diagnostics Report ===")
        print("Root path: \(rootURL.path)")
        print("DB path: \(databasePath)")
        print("")

        print("[A] Filesystem Reality")
        let fsReport = enumerateFilesystem(rootURL: rootURL)
        print("Total regular files: \(fsReport.totalFiles)")
        print("Total symlinks: \(fsReport.symlinkCount)")
        print("Symlinks skipped: true")
        if !fsReport.errors.isEmpty {
            print("Enumerator errors:")
            for err in fsReport.errors.prefix(10) {
                print("- \(err)")
            }
        }

        let known = ["json", "txt", "md", "pdf", "docx"]
        let otherCount = fsReport.extensionCounts
            .filter { !known.contains($0.key) }
            .reduce(0) { $0 + $1.value }
        print("Counts by extension:")
        for ext in known {
            let count = fsReport.extensionCounts[ext, default: 0]
            print("- .\(ext): \(count)")
        }
        print("- other: \(otherCount)")

        print("First 25 paths:")
        for path in fsReport.firstPaths.prefix(25) {
            print("- \(path)")
        }

        print("25 largest files:")
        for entry in fsReport.largestFiles.prefix(25) {
            print("- \(entry.path) (\(entry.size) bytes)")
        }

        print("25 most recent files:")
        for entry in fsReport.recentFiles.prefix(25) {
            print("- \(entry.path) (\(entry.modified))")
        }

        print("")
        print("[B] Scanner Filters")
        print("Accepted extensions: [json, txt, md, pdf, docx]")
        print("Skipped: hidden files and .DS_Store")
        print("Skipped: non-regular files")
        print("Max-file-limit: none")

        print("")
        print("[C] Parsing/Extraction Outcomes")

        var processed = 0
        var succeeded = 0
        var failed = 0
        var failureReasons: [String: Int] = [:]
        var examples: [FailureExample] = []

        let scanFiles: [URL]
        do {
            scanFiles = try scanner.scanDirectory(rootURL)
        } catch {
            print("Scanner error: \(error)")
            scanFiles = []
        }

        if let store = store {
            let indexedPaths = (try? store.getIndexedDocumentPaths()) ?? []
            let newFiles = scanner.getNewFiles(allFiles: scanFiles, indexedPaths: indexedPaths)
            print("Indexed paths in DB: \(indexedPaths.count)")
            print("New files to index: \(newFiles.count)")
        }

        print("Attempted to index (filtered): \(scanFiles.count)")

        for fileURL in scanFiles {
            processed += 1
            do {
                let ext = fileURL.pathExtension.lowercased()
                if ext != "json" {
                    let salvaged: String?
                    if ext == "pdf" {
                        salvaged = scanner.extractPDFText(from: fileURL)
                    } else {
                        salvaged = scanner.salvageText(from: fileURL)
                    }
                    if let salvaged = salvaged,
                       nonWhitespaceCount(in: salvaged) >= 50 {
                        succeeded += 1
                    } else {
                        throw CorruptEpisodeFile.invalidUTF8
                    }
                } else {
                    _ = try parser.parse(fileURL: fileURL)
                    succeeded += 1
                }
            } catch {
                if shouldAttemptSalvage(error: error) {
                    if let salvaged = scanner.salvageText(from: fileURL),
                       nonWhitespaceCount(in: salvaged) >= 50 {
                        succeeded += 1
                        continue
                    }
                }

                failed += 1
                let reason = classifyFailure(error: error)
                failureReasons[reason, default: 0] += 1

                if examples.count < 10 {
                    let (hex, size, encodingGuess) = sampleFileInfo(url: fileURL, scanner: scanner)
                    let example = FailureExample(
                        path: relativePath(rootURL: rootURL, fileURL: fileURL),
                        firstBytesHex: hex,
                        fileSize: size,
                        encodingGuess: encodingGuess,
                        error: shortError(error)
                    )
                    examples.append(example)
                }
            }
        }

        print("Processed: \(processed)")
        print("Succeeded: \(succeeded)")
        print("Failed: \(failed)")
        print("Failures by reason:")
        for (reason, count) in failureReasons.sorted(by: { $0.value > $1.value }) {
            print("- \(reason): \(count)")
        }

        if !examples.isEmpty {
            print("Failure examples:")
            for ex in examples {
                print("- \(ex.path) | size=\(ex.fileSize) | bytes=\(ex.firstBytesHex) | encoding=\(ex.encodingGuess) | error=\(ex.error)")
            }
        }

        print("")
        print("[D] SQLite State")
        if let store = store {
            print("DB path: \(store.databasePath)")
            let docCount = (try? store.countRows(table: "documents")) ?? -1
            let chunkCount = (try? store.countRows(table: "chunks")) ?? -1
            let ftsCount = (try? store.countRows(table: "chunks_fts")) ?? -1
            let savedNoteCount = (try? store.countDocuments(sourceType: .atlasNote)) ?? -1
            let badFileCount = (try? store.countRows(table: "bad_files")) ?? -1

            print("documents: \(docCount)")
            print("chunks: \(chunkCount)")
            print("chunks_fts: \(ftsCount)")
            print("documents (saved notes): \(savedNoteCount)")
            print("bad_files: \(badFileCount)")

            if let last = try? store.getLastDocuments(limit: 10) {
                print("Last 10 documents:")
                for doc in last {
                    print("- \(doc.id) | \(doc.sourcePath) | created=\(doc.createdAt) | indexed=\(doc.indexedAt)")
                }
            }

            if let bad = try? store.getBadFiles(limit: 10), !bad.isEmpty {
                print("Bad files (most recent):")
                for entry in bad {
                    print("- \(entry.path) | mtime=\(entry.mtime) | lastSeen=\(entry.lastSeenAt) | error=\(entry.error)")
                }
            }
        } else {
            print("DB unavailable")
        }

        print("=== End Diagnostics ===")
    }

    private static func enumerateFilesystem(rootURL: URL) -> (totalFiles: Int, symlinkCount: Int, extensionCounts: [String: Int], firstPaths: [String], largestFiles: [(path: String, size: Int)], recentFiles: [(path: String, modified: Date)], errors: [String]) {
        var totalFiles = 0
        var symlinkCount = 0
        var extensionCounts: [String: Int] = [:]
        var firstPaths: [String] = []
        var largestFiles: [(path: String, size: Int)] = []
        var recentFiles: [(path: String, modified: Date)] = []
        var errors: [String] = []

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { url, error in
                errors.append("\(url.path): \(error)")
                return true
            }
        )

        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true {
                symlinkCount += 1
                continue
            }
            guard values?.isRegularFile == true else { continue }

            totalFiles += 1
            let ext = url.pathExtension.lowercased()
            extensionCounts[ext, default: 0] += 1

            if firstPaths.count < 25 {
                firstPaths.append(relativePath(rootURL: rootURL, fileURL: url))
            }

            let size = values?.fileSize ?? 0
            let relPath = relativePath(rootURL: rootURL, fileURL: url)

            largestFiles.append((relPath, size))
            if largestFiles.count > 25 {
                largestFiles.sort { $0.size > $1.size }
                largestFiles = Array(largestFiles.prefix(25))
            }

            if let mod = values?.contentModificationDate {
                recentFiles.append((relPath, mod))
                if recentFiles.count > 25 {
                    recentFiles.sort { $0.modified > $1.modified }
                    recentFiles = Array(recentFiles.prefix(25))
                }
            }
        }

        largestFiles.sort { $0.size > $1.size }
        recentFiles.sort { $0.modified > $1.modified }

        return (totalFiles, symlinkCount, extensionCounts, firstPaths, largestFiles, recentFiles, errors)
    }

    private static func classifyFailure(error: Error) -> String {
        if error is DecodingError { return "decoding error" }
        if let corrupt = error as? CorruptEpisodeFile {
            switch corrupt {
            case .empty:
                return "empty content"
            default:
                return "unreadable"
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == 3840 {
            return "decoding error"
        }
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == 13 {
            return "permissions"
        }
        return "other"
    }

    private static func sampleFileInfo(url: URL, scanner: DocumentScanner) -> (String, Int, String) {
        guard let data = try? Data(contentsOf: url) else { return ("", 0, "unreadable") }
        let size = data.count
        let firstBytes = data.prefix(16)
        let hex = firstBytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        let encodingGuess = guessEncoding(data: data, scanner: scanner)
        return (hex, size, encodingGuess)
    }

    private static func guessEncoding(data: Data, scanner: DocumentScanner) -> String {
        if data.count >= 2 {
            if data[0] == 0xFF && data[1] == 0xFE { return "utf16le" }
            if data[0] == 0xFE && data[1] == 0xFF { return "utf16be" }
        }
        let sampleCount = min(64, data.count)
        if sampleCount >= 4 {
            var nullsEven = 0
            var nullsOdd = 0
            for i in 0..<sampleCount {
                if data[i] == 0x00 {
                    if i % 2 == 0 { nullsEven += 1 } else { nullsOdd += 1 }
                }
            }
            let nullRatio = Float(nullsEven + nullsOdd) / Float(sampleCount)
            if nullRatio >= 0.3 {
                return nullsOdd > nullsEven ? "utf16le" : "utf16be"
            }
        }
        if scanner.decodeTextLenient(data) != nil { return "utf8" }
        return "unknown"
    }

    private static func shortError(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription {
            return localized
        }
        return String(describing: error)
    }

    private static func relativePath(rootURL: URL, fileURL: URL) -> String {
        let rootPath = rootURL.path
        let path = fileURL.path
        if path.hasPrefix(rootPath) {
            let start = path.index(path.startIndex, offsetBy: rootPath.count)
            let rel = String(path[start...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return rel.isEmpty ? "." : rel
        }
        return path
    }
}

private func shouldAttemptSalvage(error: Error) -> Bool {
    if error is DecodingError { return true }
    if error is CorruptEpisodeFile { return true }
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain && nsError.code == 3840 {
        return true
    }
    return false
}

private func nonWhitespaceCount(in text: String) -> Int {
    return text.reduce(0) { count, char in
        char.isWhitespace ? count : count + 1
    }
}

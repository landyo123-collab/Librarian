import Foundation
import PDFKit

public class DocumentScanner {
    public let acceptedExtensions: Set<String> = ["json", "txt", "md", "pdf", "docx", "py", "swift"]

    public init() {}

    public func scanDirectory(_ url: URL, allowedExtensions: Set<String>? = nil) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ScannerError.directoryNotFound(url.path)
        }

        let allowed = allowedExtensions ?? acceptedExtensions
        var files: [URL] = []
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [],
            errorHandler: { _, _ in true }
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            let name = fileURL.lastPathComponent
            if name.hasPrefix(".") || name == ".DS_Store" { continue }

            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                if resourceValues.isRegularFile == true {
                    let ext = fileURL.pathExtension.lowercased()
                    if allowed.contains(ext) {
                        files.append(fileURL)
                    }
                }
            } catch {
                // Skip files we can't access
                continue
            }
        }

        return files.sorted { $0.path < $1.path }
    }

    public func getNewFiles(allFiles: [URL], indexedPaths: Set<String>) -> [URL] {
        return allFiles.filter { !indexedPaths.contains($0.path) }
    }

    public func getFileModificationDate(_ url: URL) -> Date? {
        if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]) {
            return values.contentModificationDate
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let date = attrs[.modificationDate] as? Date {
            return date
        }
        return nil
    }

    public func salvageText(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decodeTextLenient(data)
    }

    public func extractPDFText(from url: URL) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        if let text = document.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }

        var collected: [String] = []
        collected.reserveCapacity(document.pageCount)
        for index in 0..<document.pageCount {
            if let page = document.page(at: index),
               let pageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines),
               !pageText.isEmpty {
                collected.append(pageText)
            }
        }

        let joined = collected.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    public func decodeTextLenient(_ data: Data) -> String? {
        if data.isEmpty { return nil }

        let stripped = stripLeadingNullsAndWhitespace(data)
        if stripped.isEmpty { return nil }

        if let encoding = detectUTF16Encoding(stripped) {
            if let decoded = String(data: stripped, encoding: encoding) {
                return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let decoded = String(data: stripped, encoding: .utf8) {
            let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        return nil
    }

    private func stripLeadingNullsAndWhitespace(_ data: Data) -> Data {
        var index = 0
        while index < data.count {
            let byte = data[index]
            if byte == 0x00 || byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 {
                index += 1
            } else {
                break
            }
        }
        if index == 0 { return data }
        return data.subdata(in: index..<data.count)
    }

    private func detectUTF16Encoding(_ data: Data) -> String.Encoding? {
        if data.count >= 2 {
            if data[0] == 0xFF && data[1] == 0xFE {
                return .utf16LittleEndian
            }
            if data[0] == 0xFE && data[1] == 0xFF {
                return .utf16BigEndian
            }
        }

        let sampleCount = min(64, data.count)
        if sampleCount < 4 { return nil }

        var nullsEven = 0
        var nullsOdd = 0
        for i in 0..<sampleCount {
            if data[i] == 0x00 {
                if i % 2 == 0 { nullsEven += 1 } else { nullsOdd += 1 }
            }
        }

        let nullRatio = Float(nullsEven + nullsOdd) / Float(sampleCount)
        if nullRatio < 0.3 { return nil }

        if nullsOdd > nullsEven {
            return .utf16LittleEndian
        } else {
            return .utf16BigEndian
        }
    }
}

public enum ScannerError: LocalizedError {
    case directoryNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .directoryNotFound(let path):
            return "Directory not found: \(path)"
        }
    }
}

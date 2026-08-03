import Foundation

enum PromptDetector {
    private static let promptPattern = #"(?m)(^|\n)(/[^\r\n]*) > $"#

    static func terminalPromptRange(in text: String) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(pattern: promptPattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.matches(in: text, range: nsRange).last,
              match.range.location + match.range.length == (text as NSString).length
        else { return nil }
        return Range(match.range, in: text)
    }

    static func promptPath(in text: String) -> String? {
        guard let range = terminalPromptRange(in: text) else { return nil }
        let trimmed = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(" >") ? String(trimmed.dropLast(2)) : trimmed
    }

    static func responseBeforePrompt(_ text: String) -> String? {
        guard let range = terminalPromptRange(in: text) else { return nil }
        return String(text[..<range.lowerBound]).trimmingCharacters(in: .newlines)
    }
}

enum OutputCleaner {
    static func clean(_ output: String) -> String {
        let normalized = output.replacingOccurrences(of: "\r", with: "\n")
        let progress = try? NSRegularExpression(pattern: #"(?m)^\s*(block|disk)\s+0x[0-9a-f]+\s*$"#)
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        let withoutProgress = progress?.stringByReplacingMatches(in: normalized, range: range, withTemplate: "") ?? normalized
        return withoutProgress
            .split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(into: [String]()) { lines, line in
                let value = String(line).trimmingCharacters(in: .whitespaces)
                if value.isEmpty && lines.last?.isEmpty == true { return }
                lines.append(value)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum AkaiOutputParser {
    static func parseDF(_ output: String) -> ([AkaiDisk], [AkaiPartition]) {
        var disks: [AkaiDisk] = []
        var partitions: [AkaiPartition] = []
        var currentDisk = 0

        for rawLine in normalizedLines(output) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("/disk"), let number = Int(line.dropFirst(5).prefix { $0.isNumber }) {
                currentDisk = number
            }

            let columns = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if columns.count >= 8,
               let diskNumber = Int(columns[0]),
               let partCount = Int(columns[2]),
               let blockSize = parseNumber(columns[3]),
               let total = parseNumber(columns[4]),
               let free = parseNumber(columns[6]),
               columns[1] != "type" {
                disks.append(AkaiDisk(
                    number: diskNumber,
                    type: columns[1],
                    partitionCount: partCount,
                    blockSize: blockSize,
                    totalBlocks: total,
                    freeBlocks: free
                ))
                currentDisk = diskNumber
                continue
            }

            if columns.count >= 7,
               columns[0].count == 1,
               columns[0].first?.isLetter == true,
               let start = parseNumber(columns[2]),
               let total = parseNumber(columns[3]),
               let free = parseNumber(columns[5]),
               columns[1] != "type" {
                partitions.append(AkaiPartition(
                    diskNumber: currentDisk,
                    letter: columns[0],
                    type: columns[1],
                    startBlock: start,
                    totalBlocks: total,
                    freeBlocks: free
                ))
            }
        }
        return (unique(disks, by: \.number), unique(partitions, by: \.id))
    }

    static func parseDirectory(_ output: String) -> ([AkaiFile], Int?, Int) {
        let pattern = #"^\s*(\d+)\s+(.+?)\s+(\d+)\s+(0x[0-9a-fA-F]+)(?:\s+(\S+))?\s*$"#
        let regex = try? NSRegularExpression(pattern: pattern)
        var files: [AkaiFile] = []
        var maximum: Int?
        var reportedCount = 0

        for line in normalizedLines(output) {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = regex?.firstMatch(in: line, range: range),
               let index = capture(match, 1, in: line).flatMap(Int.init),
               let name = capture(match, 2, in: line),
               let size = capture(match, 3, in: line).flatMap(Int64.init),
               let startText = capture(match, 4, in: line) {
                let type = inferType(from: name)
                files.append(AkaiFile(
                    index: index,
                    name: name.trimmingCharacters(in: .whitespaces),
                    type: type,
                    byteSize: size,
                    startBlock: parseNumber(startText),
                    compression: capture(match, 5, in: line)
                ))
            }
            if line.contains("total:"), line.contains("file(s)") {
                let numberRegex = try? NSRegularExpression(pattern: #"\d+"#)
                let lineRange = NSRange(line.startIndex..<line.endIndex, in: line)
                let values = (numberRegex?.matches(in: line, range: lineRange) ?? []).compactMap { match -> Int? in
                    guard let range = Range(match.range, in: line) else { return nil }
                    return Int(line[range])
                }
                if let first = values.first { reportedCount = first }
                if values.count > 1 { maximum = values[1] }
            }
        }
        return (files, maximum, reportedCount)
    }

    static func parseVolumes(_ output: String) -> [AkaiVolume] {
        var paths: [String] = []
        for line in normalizedLines(output) {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(" >") {
                trimmed = String(trimmed.dropLast(2))
            }
            guard trimmed.hasPrefix("/disk") else { continue }
            let components = trimmed.split(separator: "/")
            guard components.count >= 3 else { continue }
            let path = "/" + components.prefix(3).joined(separator: "/")
            if !paths.contains(path) { paths.append(path) }
        }
        return paths.enumerated().map { offset, path in
            AkaiVolume(name: path.split(separator: "/").last.map(String.init) ?? path, path: path, index: offset + 1)
        }
    }

    static func currentPath(_ output: String) -> String? {
        PromptDetector.promptPath(in: output)
            ?? normalizedLines(output).map { $0.trimmingCharacters(in: .whitespaces) }.last { $0.hasPrefix("/") }
    }

    private static func normalizedLines(_ output: String) -> [String] {
        output.replacingOccurrences(of: "\r", with: "\n").components(separatedBy: .newlines)
    }

    private static func parseNumber(_ value: String) -> Int? {
        if value.lowercased().hasPrefix("0x") {
            return Int(value.dropFirst(2), radix: 16)
        }
        return Int(value)
    }

    private static func capture(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        guard index < match.numberOfRanges,
              match.range(at: index).location != NSNotFound,
              let range = Range(match.range(at: index), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func inferType(from name: String) -> String {
        switch (name as NSString).pathExtension.uppercased() {
        case "S", "S9": return "Sample"
        case "P", "P1", "P3", "P9": return "Program"
        case "M": return "Multi"
        case "X": return "Cue List"
        default: return "File"
        }
    }

    private static func unique<T, Key: Hashable>(_ values: [T], by keyPath: KeyPath<T, Key>) -> [T] {
        var seen = Set<Key>()
        return values.filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}

enum USBVolumeResolver {
    static func owningVolume(for fileURL: URL) -> URL? {
        let standardized = fileURL.standardizedFileURL.path
        guard standardized.hasPrefix("/Volumes/") else { return nil }
        let components = standardized.split(separator: "/")
        guard components.count >= 2 else { return nil }
        return URL(fileURLWithPath: "/Volumes/\(components[1])", isDirectory: true)
    }

    static func exactCopyDestination(
        source: URL,
        mountedVolumes: [URL],
        fileManager: FileManager = .default
    ) -> URL? {
        let sourceVolume = owningVolume(for: source)
        return mountedVolumes
            .filter { $0.standardizedFileURL != sourceVolume?.standardizedFileURL }
            .map { $0.appendingPathComponent(source.lastPathComponent) }
            .first { fileManager.fileExists(atPath: $0.path) }
    }
}

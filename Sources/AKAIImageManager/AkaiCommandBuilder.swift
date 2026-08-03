import Foundation

enum AkaiCommandBuilder {
    static func validate(_ command: String) throws -> String {
        guard !command.isEmpty,
              !command.contains("\n"),
              !command.contains("\r"),
              command.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7f })
        else {
            throw AppError.unsafeCommand("Commands must be a single printable line.")
        }
        return command
    }

    static func externalToken(_ value: String) throws -> String {
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else {
            throw AppError.unsafeCommand("AKAI Util cannot parse spaces in local paths. A safe temporary alias is required.")
        }
        guard !value.contains("\n"), !value.contains("\r") else {
            throw AppError.unsafeCommand("The path contains a line break.")
        }
        return value
    }

    static func akaiPathToken(_ value: String) throws -> String {
        guard !value.contains("\n"), !value.contains("\r") else {
            throw AppError.unsafeCommand("The AKAI path contains a line break.")
        }
        return value.replacingOccurrences(of: " ", with: "_")
    }

    static func changeDirectory(_ path: String) throws -> String {
        "cd \(try akaiPathToken(path))"
    }

    static func localDirectory(_ path: String) throws -> String {
        "lcd \(try externalToken(path))"
    }

    static func delete(index: Int) throws -> String {
        guard index > 0 else { throw AppError.unsafeCommand("File indexes start at 1.") }
        return "deli \(index)"
    }

    static func delete(path: String) throws -> String {
        "del \(try akaiPathToken(path))"
    }

    static func importWAV(filename: String, options: ImportOptions) throws -> String {
        let command = options.compressedS900 ? "wav2sample9c" : "wav2sample9"
        return "\(command) \(try externalToken(filename))"
    }

    static func exportWAV(index: Int) throws -> String {
        guard index > 0 else { throw AppError.unsafeCommand("File indexes start at 1.") }
        return "sample2wavi \(index)"
    }

    static func importNative(filename: String) throws -> String {
        "put \(try externalToken(filename))"
    }

    static func exportNative(index: Int) throws -> String {
        guard index > 0 else { throw AppError.unsafeCommand("File indexes start at 1.") }
        return "geti \(index)"
    }

    static func fileInformation(index: Int) throws -> String {
        guard index > 0 else {
            throw AppError.unsafeCommand("File indexes start at 1.")
        }
        return "infoi \(index)"
    }

    static func fixRAMName(index: Int) throws -> String {
        guard index > 0 else { throw AppError.unsafeCommand("File indexes start at 1.") }
        return "fixramnamei \(index)"
    }

    static func deletionOrder(_ indexes: [Int]) -> [Int] {
        Array(Set(indexes.filter { $0 > 0 })).sorted(by: >)
    }

    static func modifiesImage(_ command: String) -> Bool {
        guard let verb = command.split(whereSeparator: \.isWhitespace).first
        else { return false }
        return [
            "del",
            "deli",
            "fixramnameall",
            "fixramnamei",
            "formatfloppyh9",
            "formatfloppyl9",
            "formatharddisk9",
            "mkvol9",
            "put",
            "wav2sample9",
            "wav2sample9c"
        ].contains(verb.lowercased())
    }
}

enum AkaiFilename {
    private static let s950AllowedCharacters = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
    )

    static func sanitizedBase(_ name: String, family: AkaiFamily, maximumLength: Int = 12) -> String {
        let stem = (name as NSString).deletingPathExtension
        let folded = stem.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
        var result = folded.uppercased().map {
            s950AllowedCharacters.contains($0) ? $0 : "_"
        }
        while result.first == "_" { result.removeFirst() }
        while result.last == "_" { result.removeLast() }
        if result.isEmpty { result = Array("SAMPLE") }
        let familyLimit = min(maximumLength, 10)
        return String(result.prefix(familyLimit))
    }

    static func normalizedS950Base(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    static func s950BaseValidationError(_ name: String) -> String? {
        let normalized = normalizedS950Base(name)
        guard !normalized.isEmpty else {
            return "Enter a sample name."
        }
        guard normalized.count <= 10 else {
            return "S950 names are limited to 10 characters."
        }
        guard normalized.allSatisfy({ s950AllowedCharacters.contains($0) }) else {
            return "Use only A–Z, 0–9, underscore or hyphen."
        }
        guard normalized.first != "_", normalized.last != "_" else {
            return "An S950 name cannot begin or end with an underscore."
        }
        return nil
    }

    static func validatedS950Base(_ name: String) throws -> String {
        if let validationError = s950BaseValidationError(name) {
            throw AppError.verificationFailed(validationError)
        }
        return normalizedS950Base(name)
    }

    static func uniqueName(base: String, existing: Set<String>, maximumLength: Int = 12) -> String {
        guard existing.contains(base.uppercased()) else { return base }
        for number in 2...999 {
            let suffix = "_\(number)"
            let prefix = String(base.prefix(max(1, maximumLength - suffix.count)))
            let candidate = prefix + suffix
            if !existing.contains(candidate.uppercased()) { return candidate }
        }
        return String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(maximumLength))
    }
}

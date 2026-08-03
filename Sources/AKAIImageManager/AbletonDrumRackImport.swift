import Foundation

enum AbletonDrumRackNote {
    /// Live stores Drum Rack receiving notes in reverse order: MIDI C1 (36)
    /// is persisted as 92, C#1 (37) as 91, and MIDI 127 as 1.
    static func midiNote(fromReceivingValue value: Int) -> Int? {
        guard (1...128).contains(value) else { return nil }
        return 128 - value
    }

    static func receivingValue(forMIDINote note: Int) -> Int {
        128 - min(127, max(0, note))
    }
}

struct AbletonDrumRackSample: Identifiable, Equatable {
    var id: Int { sourceNote }
    let sourceNote: Int
    let sourceName: String
    let sampleURL: URL
    let detectedRootNote: Int
    let detuneCents: Int
    let s950Filter: Int
    let s950VelocityLoudness: Int
    let s950VelocityFilter: Int
}

struct AbletonDrumRackPreset: Equatable {
    let sourceURL: URL
    let samples: [AbletonDrumRackSample]
}

enum AbletonDrumRackError: LocalizedError, Equatable {
    case unreadablePreset(String)
    case invalidXML
    case noSamplerPads
    case missingSamplePath(note: Int)
    case missingSampleFile(String)
    case multipleSamplesOnPad(note: Int)
    case duplicatePadNote(Int)
    case invalidReceivingNote(Int)
    case tooManyKeygroups(Int)

    var errorDescription: String? {
        switch self {
        case .unreadablePreset(let detail):
            return "The Ableton preset could not be read: \(detail)"
        case .invalidXML:
            return "The ADG does not contain readable Ableton preset XML."
        case .noSamplerPads:
            return "No Drum Rack pads containing supported sample devices were found in this ADG."
        case .missingSamplePath(let note):
            return "The pad on \(P9Keygroup.noteName(note)) has a sample but no usable WAV path."
        case .missingSampleFile(let path):
            return "An Ableton sample is missing: \(path)"
        case .multipleSamplesOnPad(let note):
            return "The pad on \(P9Keygroup.noteName(note)) contains multiple Sampler zones. This importer currently supports one sample per pad."
        case .duplicatePadNote(let note):
            return "More than one Drum Rack branch receives \(P9Keygroup.noteName(note))."
        case .invalidReceivingNote(let value):
            return "A Drum Rack branch contains invalid Ableton receiving-note value \(value)."
        case .tooManyKeygroups(let count):
            return "The import would create \(count) keygroups; an S950 program supports at most 99."
        }
    }
}

enum AbletonDrumRackParser {
    static func parse(url: URL) throws -> AbletonDrumRackPreset {
        let data = try presetXMLData(at: url)
        let delegate = AbletonXMLDelegate(sourceURL: url)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw AbletonDrumRackError.invalidXML
        }
        let parsed = try delegate.result()
        guard !parsed.isEmpty else {
            throw AbletonDrumRackError.noSamplerPads
        }
        return AbletonDrumRackPreset(sourceURL: url, samples: parsed)
    }

    static func parseXML(_ data: Data, sourceURL: URL) throws -> AbletonDrumRackPreset {
        let delegate = AbletonXMLDelegate(sourceURL: sourceURL)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw AbletonDrumRackError.invalidXML
        }
        let parsed = try delegate.result()
        guard !parsed.isEmpty else {
            throw AbletonDrumRackError.noSamplerPads
        }
        return AbletonDrumRackPreset(sourceURL: sourceURL, samples: parsed)
    }

    private static func presetXMLData(at url: URL) throws -> Data {
        let raw: Data
        do {
            raw = try Data(contentsOf: url)
        } catch {
            throw AbletonDrumRackError.unreadablePreset(error.localizedDescription)
        }
        guard raw.count >= 2 else {
            throw AbletonDrumRackError.invalidXML
        }
        guard raw[0] == 0x1F, raw[1] == 0x8B else {
            return raw
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", url.path]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw AbletonDrumRackError.unreadablePreset(error.localizedDescription)
        }
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !output.isEmpty else {
            let detail = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AbletonDrumRackError.unreadablePreset(
                detail.isEmpty ? "gzip decompression failed." : detail
            )
        }
        return output
    }
}

private final class AbletonXMLDelegate: NSObject, XMLParserDelegate {
    private struct SamplePart {
        var name = ""
        var absolutePath = ""
        var relativePath = ""
        var sampleFilename = ""
        var relativePathComponents: [String] = []
        var pathHintComponents: [String] = []
        var rootNote = 60
        var detuneCents = 0
    }

    private struct Branch {
        var receivingNote: Int?
        var parts: [SamplePart] = []
        var filterEnabled = false
        var filterFrequency = 22_000.0
        var velocityToLoudness = 0.0
        var velocityToFilter = 0.0
    }

    private let sourceURL: URL
    private var depth = 0
    private var branchDepth: Int?
    private var samplerDepth: Int?
    private var partDepth: Int?
    private var sampleRefDepth: Int?
    private var relativePathDepth: Int?
    private var pathHintDepth: Int?
    private var filterDepth: Int?
    private var filterOnDepth: Int?
    private var simplerFilterDepth: Int?
    private var filterFrequencyDepth: Int?
    private var filterVelocityDepth: Int?
    private var volumeVelocityDepth: Int?
    private var branch: Branch?
    private var part: SamplePart?
    private var branches: [Branch] = []

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        depth += 1
        let value = attributeDict["Value"] ?? ""

        if elementName == "DrumBranchPreset" {
            branchDepth = depth
            branch = Branch()
            return
        }
        guard branch != nil else { return }

        if elementName == "ReceivingNote", let note = Int(value) {
            branch?.receivingNote = note
            return
        }

        if elementName == "MultiSampler"
            || elementName == "OriginalSimpler"
            || elementName == "Simpler" {
            samplerDepth = depth
        }
        if let samplerDepth {
            if elementName == "Filter", depth == samplerDepth + 1 {
                filterDepth = depth
            } else if elementName == "IsOn",
                      let filterDepth,
                      depth == filterDepth + 1 {
                filterOnDepth = depth
            } else if elementName == "SimplerFilter" {
                simplerFilterDepth = depth
            } else if elementName == "Freq",
                      let simplerFilterDepth,
                      depth == simplerFilterDepth + 1 {
                filterFrequencyDepth = depth
            } else if elementName == "ModByVelocity",
                      let simplerFilterDepth,
                      depth == simplerFilterDepth + 1 {
                filterVelocityDepth = depth
            } else if elementName == "VolumeVelScale" {
                volumeVelocityDepth = depth
            } else if elementName == "Manual" {
                if let filterOnDepth, depth == filterOnDepth + 1 {
                    branch?.filterEnabled = Self.boolValue(value)
                } else if let filterFrequencyDepth,
                          depth == filterFrequencyDepth + 1,
                          let frequency = Double(value) {
                    branch?.filterFrequency = frequency
                } else if let filterVelocityDepth,
                          depth == filterVelocityDepth + 1,
                          let amount = Double(value) {
                    branch?.velocityToFilter = amount
                } else if let volumeVelocityDepth,
                          depth == volumeVelocityDepth + 1,
                          let amount = Double(value) {
                    branch?.velocityToLoudness = amount
                }
            }
        }

        if elementName == "MultiSamplePart" {
            partDepth = depth
            part = SamplePart()
            return
        }
        guard var currentPart = part, let partDepth else { return }

        if elementName == "SampleRef" {
            sampleRefDepth = depth
        } else if sampleRefDepth != nil, elementName == "RelativePath" {
            relativePathDepth = depth
        } else if sampleRefDepth != nil, elementName == "PathHint" {
            pathHintDepth = depth
        } else if sampleRefDepth != nil,
                  elementName == "RelativePathElement",
                  let directory = attributeDict["Dir"],
                  !directory.isEmpty {
            if pathHintDepth != nil {
                currentPart.pathHintComponents.append(directory)
            } else if relativePathDepth != nil {
                currentPart.relativePathComponents.append(directory)
            }
        } else if sampleRefDepth != nil,
                  elementName == "Name",
                  Self.isSupportedAudioPath(value) {
            currentPart.sampleFilename = value
        }

        if depth == partDepth + 1 {
            switch elementName {
            case "Name":
                currentPart.name = value
            case "RootKey":
                currentPart.rootNote = Int(value) ?? 60
            case "Detune":
                currentPart.detuneCents = Int(value) ?? 0
            default:
                break
            }
        } else if elementName == "Path",
                  !value.isEmpty,
                  Self.isSupportedAudioPath(value),
                  currentPart.absolutePath.isEmpty {
            currentPart.absolutePath = value
        } else if elementName == "RelativePath",
                  !value.isEmpty,
                  Self.isSupportedAudioPath(value),
                  currentPart.relativePath.isEmpty {
            currentPart.relativePath = value
        }
        part = currentPart
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "MultiSamplePart", let completedPart = part {
            branch?.parts.append(completedPart)
            part = nil
            partDepth = nil
            sampleRefDepth = nil
            relativePathDepth = nil
            pathHintDepth = nil
        } else if elementName == "DrumBranchPreset", let completedBranch = branch {
            branches.append(completedBranch)
            branch = nil
            branchDepth = nil
            samplerDepth = nil
            filterDepth = nil
            filterOnDepth = nil
            simplerFilterDepth = nil
            filterFrequencyDepth = nil
            filterVelocityDepth = nil
            volumeVelocityDepth = nil
        }
        if elementName == "SampleRef" {
            sampleRefDepth = nil
        } else if elementName == "RelativePath" {
            relativePathDepth = nil
        } else if elementName == "PathHint" {
            pathHintDepth = nil
        } else if elementName == "Freq", depth == filterFrequencyDepth {
            filterFrequencyDepth = nil
        } else if elementName == "ModByVelocity", depth == filterVelocityDepth {
            filterVelocityDepth = nil
        } else if elementName == "VolumeVelScale", depth == volumeVelocityDepth {
            volumeVelocityDepth = nil
        } else if elementName == "SimplerFilter", depth == simplerFilterDepth {
            simplerFilterDepth = nil
        } else if elementName == "IsOn", depth == filterOnDepth {
            filterOnDepth = nil
        } else if elementName == "Filter", depth == filterDepth {
            filterDepth = nil
        } else if (elementName == "MultiSampler"
                    || elementName == "OriginalSimpler"
                    || elementName == "Simpler"),
                  depth == samplerDepth {
            samplerDepth = nil
        }
        depth -= 1
    }

    func result() throws -> [AbletonDrumRackSample] {
        var result: [AbletonDrumRackSample] = []
        var seenNotes = Set<Int>()

        for branch in branches {
            guard let receivingValue = branch.receivingNote else { continue }
            guard let note = AbletonDrumRackNote.midiNote(
                fromReceivingValue: receivingValue
            ) else {
                throw AbletonDrumRackError.invalidReceivingNote(
                    receivingValue
                )
            }
            guard !branch.parts.isEmpty else { continue }
            guard branch.parts.count == 1 else {
                throw AbletonDrumRackError.multipleSamplesOnPad(note: note)
            }
            guard seenNotes.insert(note).inserted else {
                throw AbletonDrumRackError.duplicatePadNote(note)
            }
            let part = branch.parts[0]
            guard let sampleURL = resolvedURL(for: part) else {
                throw AbletonDrumRackError.missingSamplePath(note: note)
            }
            guard FileManager.default.fileExists(atPath: sampleURL.path) else {
                throw AbletonDrumRackError.missingSampleFile(sampleURL.path)
            }
            let fallbackName = sampleURL.deletingPathExtension().lastPathComponent
            result.append(
                AbletonDrumRackSample(
                    sourceNote: note,
                    sourceName: part.name.isEmpty ? fallbackName : part.name,
                    sampleURL: sampleURL,
                    detectedRootNote: part.rootNote,
                    detuneCents: part.detuneCents,
                    s950Filter: Self.s950Filter(
                        enabled: branch.filterEnabled,
                        cutoffHz: branch.filterFrequency
                    ),
                    s950VelocityLoudness: Self.s950Sensitivity(
                        branch.velocityToLoudness
                    ),
                    s950VelocityFilter: branch.filterEnabled
                        ? Self.s950Sensitivity(branch.velocityToFilter)
                        : 0
                )
            )
        }
        // Ableton persists DrumBranchPreset elements in rack/pad order and its
        // stored ReceivingNote values run opposite to ordinary MIDI notes.
        // Preserve document order after decoding rather than numerically
        // sorting the branches.
        return result
    }

    private func resolvedURL(for part: SamplePart) -> URL? {
        if !part.absolutePath.isEmpty {
            return URL(fileURLWithPath: part.absolutePath).standardizedFileURL
        }
        if !part.relativePath.isEmpty {
            var parent = sourceURL.deletingLastPathComponent()
            while parent.path != "/" {
                let candidate = parent
                    .appendingPathComponent(part.relativePath)
                    .standardizedFileURL
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
                parent.deleteLastPathComponent()
            }
            let direct = sourceURL.deletingLastPathComponent()
                .appendingPathComponent(part.relativePath)
                .standardizedFileURL
            if FileManager.default.fileExists(atPath: direct.path) {
                return direct
            }
        }
        if !part.sampleFilename.isEmpty {
            if let relative = resolvedComponentPath(
                part.relativePathComponents,
                filename: part.sampleFilename
            ) {
                return relative
            }
            let hinted = URL(fileURLWithPath: "/")
                .appendingPathComponent(
                    (part.pathHintComponents + [part.sampleFilename])
                        .joined(separator: "/")
                )
                .standardizedFileURL
            if FileManager.default.fileExists(atPath: hinted.path) {
                return hinted
            }
        }
        return nil
    }

    private func resolvedComponentPath(
        _ components: [String],
        filename: String
    ) -> URL? {
        guard !components.isEmpty else { return nil }
        var parent = sourceURL.deletingLastPathComponent()
        while parent.path != "/" {
            var candidate = parent
            for component in components {
                candidate.appendPathComponent(component)
            }
            candidate.appendPathComponent(filename)
            candidate = candidate.standardizedFileURL
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            parent.deleteLastPathComponent()
        }
        return nil
    }

    private static func isSupportedAudioPath(_ path: String) -> Bool {
        (path as NSString).pathExtension.caseInsensitiveCompare("wav")
            == .orderedSame
    }

    private static func boolValue(_ value: String) -> Bool {
        value == "1" || value.caseInsensitiveCompare("true") == .orderedSame
    }

    private static func s950Sensitivity(_ amount: Double) -> Int {
        Int((min(1, max(0, amount)) * 99).rounded())
    }

    private static func s950Filter(enabled: Bool, cutoffHz: Double) -> Int {
        guard enabled else { return 99 }
        let minimum = 30.0
        let maximum = 22_000.0
        let clamped = min(maximum, max(minimum, cutoffHz))
        let normalized = log(clamped / minimum) / log(maximum / minimum)
        return Int((normalized * 99).rounded())
    }
}

struct AbletonDrumRackImportRow: Identifiable, Equatable {
    var id: Int { source.sourceNote }
    let source: AbletonDrumRackSample
    var sampleName: String
}

struct AbletonDrumRackImportDraft: Identifiable, Equatable {
    let id = UUID()
    let sourceURL: URL
    var startNote: Int
    var rootNote: Int
    var midiChannel: Int
    var output: P9Output
    var compressedSamples: Bool
    var rows: [AbletonDrumRackImportRow]
    let reservedSampleNames: Set<String>
    let existingKeygroupCount: Int
    let existingKeyRanges: [ClosedRange<Int>]
    let replacesBlankKeygroup: Bool

    init(
        preset: AbletonDrumRackPreset,
        startNote: Int,
        existingSampleNames: [String],
        existingKeygroupCount: Int,
        existingKeyRanges: [ClosedRange<Int>] = [],
        replacesBlankKeygroup: Bool = false
    ) {
        sourceURL = preset.sourceURL
        self.startNote = startNote
        let detectedRoots = Set(preset.samples.map(\.detectedRootNote))
        rootNote = detectedRoots.count == 1 ? detectedRoots.first ?? 60 : 60
        midiChannel = 1
        output = .all
        compressedSamples = false
        reservedSampleNames = Set(existingSampleNames.map(Self.nameKey))
        self.existingKeygroupCount = existingKeygroupCount
        self.existingKeyRanges = existingKeyRanges
        self.replacesBlankKeygroup = replacesBlankKeygroup

        var used = reservedSampleNames
        rows = preset.samples.map { sample in
            var base = AkaiFilename.sanitizedBase(
                sample.sourceName,
                family: .s900,
                maximumLength: 10
            )
            while base.last == "_" {
                base.removeLast()
            }
            if base.isEmpty {
                base = "SAMPLE"
            }
            base = Self.samplerVisibleName(base)
            let unique = Self.uniqueSampleName(base: base, usedKeys: used)
            used.insert(Self.nameKey(unique))
            return AbletonDrumRackImportRow(source: sample, sampleName: unique)
        }
    }

    func targetNote(for row: AbletonDrumRackImportRow) -> Int {
        guard let first = rows.first,
              let index = rows.firstIndex(where: { $0.id == row.id })
        else { return startNote }
        let lastNote = rows.last?.source.sourceNote ?? first.source.sourceNote
        let direction = lastNote >= first.source.sourceNote ? 1 : -1
        let directedOffset =
            (row.source.sourceNote - first.source.sourceNote) * direction
        return startNote + (directedOffset >= 0 ? directedOffset : index)
    }

    var validationError: String? {
        guard !rows.isEmpty else {
            return AbletonDrumRackError.noSamplerPads.errorDescription
        }
        let retainedKeygroupCount =
            existingKeygroupCount - (replacesBlankKeygroup ? 1 : 0)
        guard retainedKeygroupCount + rows.count <= 99 else {
            return AbletonDrumRackError.tooManyKeygroups(
                retainedKeygroupCount + rows.count
            ).errorDescription
        }
        guard (0...127).contains(startNote), (0...127).contains(rootNote) else {
            return "Start and root notes must be between 0 and 127."
        }
        let targets = rows.map(targetNote)
        guard targets.allSatisfy({ (0...127).contains($0) }) else {
            return "The mapped pads extend beyond MIDI note 127."
        }
        if let overlap = targets.first(where: { target in
            existingKeyRanges.contains(where: { $0.contains(target) })
        }) {
            return "\(P9Keygroup.noteName(overlap)) overlaps an existing keygroup. Choose another start note."
        }
        let transposes = targets.map { rootNote - $0 }
        guard transposes.allSatisfy({ P9Tuning.transposeRange.contains($0) }) else {
            return "At least one mapped pad requires transpose outside the S950 range of −50 to +50."
        }

        guard rows.allSatisfy({
            !$0.sampleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            return "Every imported sample needs a name."
        }
        let names = rows.map { cleanedSampleName($0.sampleName) }
        guard Set(names.map { $0.uppercased() }).count == names.count else {
            return "Every imported sample name must be unique."
        }
        if let collision = names.first(where: {
            reservedSampleNames.contains(Self.nameKey($0))
        }) {
            return "\(collision) already exists in this S950 volume."
        }
        return nil
    }

    func cleanedSampleName(_ value: String) -> String {
        Self.samplerVisibleName(
            AkaiFilename.sanitizedBase(
                value,
                family: .s900,
                maximumLength: 10
            )
        )
    }

    func stagingBaseName(_ value: String) -> String {
        AkaiFilename.sanitizedBase(
            cleanedSampleName(value),
            family: .s900,
            maximumLength: 10
        )
    }

    func editableSampleName(_ value: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _-")
        return String(
            value.uppercased()
                .map { allowed.contains($0) ? $0 : " " }
                .prefix(10)
        )
    }

    private static func nameKey(_ value: String) -> String {
        value.uppercased().replacingOccurrences(of: "_", with: " ")
    }

    private static func samplerVisibleName(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ")
    }

    private static func uniqueSampleName(
        base: String,
        usedKeys: Set<String>
    ) -> String {
        guard usedKeys.contains(nameKey(base)) else { return base }
        for number in 2...999 {
            let suffix = " \(number)"
            let prefix = String(base.prefix(max(1, 10 - suffix.count)))
            let candidate = prefix + suffix
            if !usedKeys.contains(nameKey(candidate)) {
                return candidate
            }
        }
        return String(
            UUID().uuidString
                .replacingOccurrences(of: "-", with: "")
                .prefix(10)
        )
    }

    func appendingKeygroups(to original: P9Program) throws -> P9Program {
        if let validationError {
            throw AppError.verificationFailed(validationError)
        }
        var program = original
        for (rowOffset, row) in rows.enumerated() {
            let index: Int
            if replacesBlankKeygroup, rowOffset == 0 {
                index = 0
            } else {
                index = try program.appendKeygroup(copying: nil)
            }
            let target = targetNote(for: row)
            let fine = Int(
                (Double(row.source.detuneCents) * 16.0 / 100.0).rounded()
            )
            program.keygroups[index].lowKey = target
            program.keygroups[index].highKey = target
            program.keygroups[index].softSampleName =
                cleanedSampleName(row.sampleName)
            program.keygroups[index].softTuning = P9Tuning(
                transpose: rootNote - target,
                fine: fine
            )
            program.keygroups[index].softFilter = row.source.s950Filter
            program.keygroups[index].velocitySensitivity.loudness =
                row.source.s950VelocityLoudness
            program.keygroups[index].velocitySensitivity.filter =
                row.source.s950VelocityFilter
            program.keygroups[index].midiChannelOffset = midiChannel - 1
            program.keygroups[index].output = output
        }
        return program
    }
}

import Foundation

enum P9ProgramError: LocalizedError, Equatable {
    case tooShort(Int)
    case invalidSize(actual: Int, expected: Int, keygroups: Int)
    case invalidKeygroup(Int)
    case invalidKeygroupRecord(Int)
    case tooManyKeygroups(Int)
    case mustKeepOneKeygroup

    var errorDescription: String? {
        switch self {
        case .tooShort(let size):
            return "The P9 file is only \(size) bytes. An S950 program header requires 38 bytes."
        case .invalidSize(let actual, let expected, let keygroups):
            return "The P9 file reports \(keygroups) keygroups and should be \(expected) bytes, but it is \(actual) bytes."
        case .invalidKeygroup(let index):
            return "Keygroup \(index + 1) is outside this program."
        case .invalidKeygroupRecord(let size):
            return "A copied keygroup is \(size) bytes; an S950 keygroup must be exactly 70 bytes."
        case .tooManyKeygroups(let count):
            return "This paste would create \(count) keygroups. An S950 program supports at most 99."
        case .mustKeepOneKeygroup:
            return "An S950 program must contain at least one keygroup."
        }
    }
}

struct P9Tuning: Equatable {
    static let transposeRange = -50...50
    static let fineRange = -8...7

    var transpose: Int
    var fine: Int

    init(rawSixteenths: Int16) {
        let raw = Int(rawSixteenths)
        // The S950 displays the signed 16-bit tuning value as the nearest
        // semitone plus a signed remainder. For example, raw 380 is shown as
        // +24 / -04, not +23 / +12, even though both describe the same pitch.
        transpose = Self.floorDiv(raw + 8, by: 16)
        fine = raw - transpose * 16
    }

    init(transpose: Int = 0, fine: Int = 0) {
        let coarse = max(
            Self.transposeRange.lowerBound,
            min(Self.transposeRange.upperBound, transpose)
        )
        let raw = coarse * 16 + fine
        self.init(rawSixteenths: Int16(clamping: raw))
    }

    var rawSixteenths: Int16 {
        let coarse = max(
            Self.transposeRange.lowerBound,
            min(Self.transposeRange.upperBound, transpose)
        ) * 16
        let fineAdjustment = max(
            Self.fineRange.lowerBound,
            min(Self.fineRange.upperBound, fine)
        )
        return Int16(max(Int(Int16.min), min(Int(Int16.max), coarse + fineAdjustment)))
    }

    func replacingTranspose(_ value: Int) -> P9Tuning {
        P9Tuning(transpose: value, fine: fine)
    }

    private static func floorDiv(_ value: Int, by divisor: Int) -> Int {
        precondition(divisor > 0)
        if value >= 0 {
            return value / divisor
        }
        return -((-value + divisor - 1) / divisor)
    }
}

enum P9Output: Hashable, Identifiable {
    case all
    case mono(Int)
    case left
    case right
    case unknown(UInt8)

    var id: UInt8 { rawValue }

    init(rawValue: UInt8) {
        switch rawValue {
        case 0xFF: self = .all
        case 0x00...0x07: self = .mono(Int(rawValue) + 1)
        case 0x08: self = .left
        case 0x09: self = .right
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: UInt8 {
        switch self {
        case .all: return 0xFF
        case .mono(let output): return UInt8(max(1, min(8, output)) - 1)
        case .left: return 0x08
        case .right: return 0x09
        case .unknown(let value): return value
        }
    }

    var displayName: String {
        switch self {
        case .all: return "00 — All / Mix"
        case .mono(let output): return String(format: "%02d — Mono %d", output, output)
        case .left: return "09 — Left"
        case .right: return "10 — Right"
        case .unknown(let value): return String(format: "Unknown — 0x%02X", value)
        }
    }

    static let standardChoices: [P9Output] = [
        .all,
        .mono(1), .mono(2), .mono(3), .mono(4),
        .mono(5), .mono(6), .mono(7), .mono(8),
        .left, .right
    ]
}

struct P9Envelope: Equatable {
    var attack: Int
    var decay: Int
    var sustain: Int
    var release: Int
}

struct P9VelocitySensitivity: Equatable {
    var loudness: Int
    var attack: Int
    var filter: Int
    var release: Int
}

struct P9Keygroup: Identifiable, Equatable {
    var id: Int
    var lowKey: Int
    var highKey: Int
    var velocityThreshold: Int

    var envelope: P9Envelope
    var velocitySensitivity: P9VelocitySensitivity

    private var rawFlags: UInt8
    var constantPitch: Bool
    var velocityCrossfade: Bool
    var oneShot: Bool
    var releaseVelocityFromNoteOn: Bool
    var customVelocityCrossfadePoint: Bool

    var output: P9Output
    var midiChannelOffset: Int

    var softSampleName: String
    var softTuning: P9Tuning
    var softFilter: Int
    var softLoudness: Int

    var loudSampleName: String
    var loudTuning: P9Tuning
    var loudFilter: Int
    var loudLoudness: Int

    var vcfEnvelope: P9Envelope
    var vcfAmount: Int
    var velocityCrossfadePoint: Int

    var isBlankFullRangePlaceholder: Bool {
        softSampleName.isEmpty
            && loudSampleName.isEmpty
            && lowKey == 0
            && highKey == 127
    }

    init(id: Int, record: Data) {
        self.id = id
        highKey = Int(record[0x00])
        lowKey = Int(record[0x01])
        velocityThreshold = Int(record[0x02])

        envelope = P9Envelope(
            attack: Int(record[0x03]),
            decay: Int(record[0x04]),
            sustain: Int(record[0x05]),
            release: Int(record[0x06])
        )
        velocitySensitivity = P9VelocitySensitivity(
            loudness: Int(record[0x0B]),
            attack: Int(record[0x09]),
            filter: Int(record[0x07]),
            release: Int(Int8(bitPattern: record[0x0A]))
        )

        let flags = record[0x12]
        rawFlags = flags
        constantPitch = flags & 0x01 != 0
        velocityCrossfade = flags & 0x02 != 0
        oneShot = flags & 0x08 != 0
        releaseVelocityFromNoteOn = flags & 0x10 != 0
        customVelocityCrossfadePoint = flags & 0x20 != 0

        output = P9Output(rawValue: record[0x13])
        midiChannelOffset = Int(record[0x14])

        softSampleName = Self.decodeName(record.subdata(in: 0x18..<0x22))
        vcfEnvelope = P9Envelope(
            attack: Int(record[0x22]),
            decay: Int(record[0x23]),
            sustain: Int(record[0x24]),
            release: Int(record[0x25])
        )
        velocityCrossfadePoint = Int(record[0x26])
        vcfAmount = Int(Int8(bitPattern: record[0x17]))
        softTuning = P9Tuning(rawSixteenths: record.signedLittleEndian16(at: 0x2A))
        softFilter = Int(record[0x2C])
        softLoudness = Int(Int8(bitPattern: record[0x2D]))

        loudSampleName = Self.decodeName(record.subdata(in: 0x2E..<0x38))
        loudTuning = P9Tuning(rawSixteenths: record.signedLittleEndian16(at: 0x40))
        loudFilter = Int(record[0x42])
        loudLoudness = Int(Int8(bitPattern: record[0x43]))
    }

    fileprivate func write(to data: inout Data, base: Int, original: P9Keygroup) {
        data[base + 0x00] = UInt8(clamping: highKey)
        data[base + 0x01] = UInt8(clamping: lowKey)
        data[base + 0x02] = UInt8(clamping: velocityThreshold)

        data[base + 0x03] = UInt8(clamping: envelope.attack)
        data[base + 0x04] = UInt8(clamping: envelope.decay)
        data[base + 0x05] = UInt8(clamping: envelope.sustain)
        data[base + 0x06] = UInt8(clamping: envelope.release)

        data[base + 0x07] = UInt8(clamping: velocitySensitivity.filter)
        data[base + 0x09] = UInt8(clamping: velocitySensitivity.attack)
        data[base + 0x0A] = UInt8(bitPattern: Int8(clamping: velocitySensitivity.release))
        data[base + 0x0B] = UInt8(clamping: velocitySensitivity.loudness)

        var flags = rawFlags
        flags = flags.setting(mask: 0x01, enabled: constantPitch)
        flags = flags.setting(mask: 0x02, enabled: velocityCrossfade)
        flags = flags.setting(mask: 0x08, enabled: oneShot)
        flags = flags.setting(mask: 0x10, enabled: releaseVelocityFromNoteOn)
        flags = flags.setting(mask: 0x20, enabled: customVelocityCrossfadePoint)
        data[base + 0x12] = flags

        data[base + 0x13] = output.rawValue
        data[base + 0x14] = UInt8(clamping: midiChannelOffset)

        if softSampleName != original.softSampleName {
            data.replaceSubrange(
                (base + 0x18)..<(base + 0x22),
                with: Self.encodedName(softSampleName)
            )
            // This address belongs to the old in-memory sample header. The
            // S950 must resolve a newly selected sample by its exact name.
            data[base + 0x28] = 0
            data[base + 0x29] = 0
        }
        data[base + 0x22] = UInt8(clamping: vcfEnvelope.attack)
        data[base + 0x23] = UInt8(clamping: vcfEnvelope.decay)
        data[base + 0x24] = UInt8(clamping: vcfEnvelope.sustain)
        data[base + 0x25] = UInt8(clamping: vcfEnvelope.release)
        data[base + 0x26] = UInt8(clamping: velocityCrossfadePoint)
        data[base + 0x17] = UInt8(bitPattern: Int8(clamping: vcfAmount))
        data.writeSignedLittleEndian16(softTuning.rawSixteenths, at: base + 0x2A)
        data[base + 0x2C] = UInt8(clamping: softFilter)
        data[base + 0x2D] = UInt8(bitPattern: Int8(clamping: softLoudness))

        if loudSampleName != original.loudSampleName {
            data.replaceSubrange(
                (base + 0x2E)..<(base + 0x38),
                with: Self.encodedName(loudSampleName)
            )
            data[base + 0x3E] = 0
            data[base + 0x3F] = 0
        }
        data.writeSignedLittleEndian16(loudTuning.rawSixteenths, at: base + 0x40)
        data[base + 0x42] = UInt8(clamping: loudFilter)
        data[base + 0x43] = UInt8(bitPattern: Int8(clamping: loudLoudness))
    }

    private static func decodeName(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
    }

    private static func encodedName(_ name: String) -> Data {
        let upper = name.uppercased()
        let ascii = upper.unicodeScalars.compactMap { scalar -> UInt8? in
            guard scalar.isASCII else { return nil }
            let value = UInt8(scalar.value)
            return value >= 0x20 && value <= 0x7E ? value : UInt8(ascii: "_")
        }
        return Data(Array(ascii.prefix(10)) + Array(repeating: UInt8(ascii: " "), count: max(0, 10 - ascii.prefix(10).count)))
    }
}

enum P9SpreadError: LocalizedError, Equatable {
    case noKeygroups
    case invalidNote(Int)
    case noteRangeTooHigh(start: Int, count: Int)
    case transposeOutOfRange(note: Int, root: Int, required: Int)

    var errorDescription: String? {
        switch self {
        case .noKeygroups:
            return "Select at least one keygroup to spread."
        case .invalidNote(let note):
            return "MIDI note \(note) is outside the valid range 0–127."
        case .noteRangeTooHigh(let start, let count):
            let end = start + count - 1
            return "This spread would end at MIDI note \(end). Choose a starting note that keeps every keygroup at or below 127."
        case .transposeOutOfRange(let note, let root, let required):
            return "MIDI note \(note) requires transpose \(required) from root note \(root), outside the S950 range of −50 to +50."
        }
    }
}

struct P9SpreadSettings: Equatable {
    var startNote = 60
    var rootNote = 60
    var automaticallyTranspose = true

    func validate(keygroupCount: Int) throws {
        guard keygroupCount > 0 else {
            throw P9SpreadError.noKeygroups
        }
        guard (0...127).contains(startNote) else {
            throw P9SpreadError.invalidNote(startNote)
        }
        guard (0...127).contains(rootNote) else {
            throw P9SpreadError.invalidNote(rootNote)
        }
        guard keygroupCount <= 128 - startNote else {
            throw P9SpreadError.noteRangeTooHigh(start: startNote, count: keygroupCount)
        }
        guard automaticallyTranspose else { return }

        for offset in 0..<keygroupCount {
            let note = startNote + offset
            let required = rootNote - note
            guard (-50...50).contains(required) else {
                throw P9SpreadError.transposeOutOfRange(
                    note: note,
                    root: rootNote,
                    required: required
                )
            }
        }
    }

    func transpose(forAssignedNote note: Int) -> Int? {
        automaticallyTranspose ? rootNote - note : nil
    }
}

struct P9Program: Equatable {
    static let headerSize = 0x26
    static let keygroupSize = 0x46
    // kg1a is the sampler-maintained address of the first keygroup. A new
    // destination program must not carry that address from the source sampler.
    private static let firstKeygroupRuntimeAddressOffset = 0x12
    // The S950 rewrites these RAM addresses when it loads the destination
    // program. Carrying values across programs can point into unrelated memory.
    private static let transferredRuntimeAddressOffsets = [0x28, 0x3E, 0x44]

    private let originalData: Data
    private let originalName: String
    private let originalPositionalCrossfadeByte: UInt8
    private var keygroupOriginalRecords: [Data]
    private var hasStructuralEdits = false

    var name: String
    var positionalCrossfade: Bool
    var keygroups: [P9Keygroup]

    init(data: Data) throws {
        guard data.count >= Self.headerSize else {
            throw P9ProgramError.tooShort(data.count)
        }
        let keygroupCount = Int(data[0x17])
        let expectedSize = Self.headerSize + keygroupCount * Self.keygroupSize
        guard data.count == expectedSize else {
            throw P9ProgramError.invalidSize(
                actual: data.count,
                expected: expectedSize,
                keygroups: keygroupCount
            )
        }

        let decodedName = String(decoding: data.subdata(in: 0x00..<0x0A), as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
        var parsedKeygroups: [P9Keygroup] = []
        var parsedRecords: [Data] = []
        parsedKeygroups.reserveCapacity(keygroupCount)
        parsedRecords.reserveCapacity(keygroupCount)
        for index in 0..<keygroupCount {
            let base = Self.headerSize + index * Self.keygroupSize
            let record = data.subdata(in: base..<(base + Self.keygroupSize))
            parsedRecords.append(record)
            parsedKeygroups.append(
                P9Keygroup(
                    id: index,
                    record: record
                )
            )
        }

        originalData = data
        originalName = decodedName
        originalPositionalCrossfadeByte = data[0x15]
        keygroupOriginalRecords = parsedRecords
        name = decodedName
        positionalCrossfade = data[0x15] != 0
        keygroups = parsedKeygroups
    }

    func encoded() throws -> Data {
        guard keygroups.count == keygroupOriginalRecords.count else {
            throw P9ProgramError.invalidSize(
                actual: Self.headerSize + keygroups.count * Self.keygroupSize,
                expected:
                    Self.headerSize
                    + keygroupOriginalRecords.count * Self.keygroupSize,
                keygroups: keygroups.count
            )
        }
        var result = originalData.subdata(in: 0..<Self.headerSize)
        result[0x17] = UInt8(keygroups.count)
        if hasStructuralEdits {
            result[Self.firstKeygroupRuntimeAddressOffset] = 0
            result[Self.firstKeygroupRuntimeAddressOffset + 1] = 0
        }
        if name != originalName {
            result.replaceSubrange(0x00..<0x0A, with: Self.encodedName(name))
        }
        if positionalCrossfade != (originalPositionalCrossfadeByte != 0) {
            result[0x15] = positionalCrossfade ? 0x01 : 0x00
        }
        for index in keygroups.indices {
            let base = Self.headerSize + index * Self.keygroupSize
            let record = keygroupOriginalRecords[index]
            result.append(record)
            let original = P9Keygroup(id: index, record: record)
            keygroups[index].write(to: &result, base: base, original: original)
        }
        return result
    }

    func keygroupRecords(at indexes: Set<Int>) throws -> [Data] {
        let data = try encoded()
        return try indexes.sorted().map { index in
            guard keygroups.indices.contains(index) else {
                throw P9ProgramError.invalidKeygroup(index)
            }
            let base = Self.headerSize + index * Self.keygroupSize
            return data.subdata(in: base..<(base + Self.keygroupSize))
        }
    }

    func destinationHeaderTemplate() throws -> Data {
        let encodedProgram = try encoded()
        var header = encodedProgram.subdata(in: 0..<Self.headerSize)
        header[Self.firstKeygroupRuntimeAddressOffset] = 0
        header[Self.firstKeygroupRuntimeAddressOffset + 1] = 0
        header[0x17] = 0
        return header
    }

    func sampleNames(at indexes: Set<Int>) throws -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        for index in indexes.sorted() {
            guard keygroups.indices.contains(index) else {
                throw P9ProgramError.invalidKeygroup(index)
            }
            for name in [
                keygroups[index].softSampleName,
                keygroups[index].loudSampleName
            ] where !name.isEmpty {
                let key = name.uppercased()
                if seen.insert(key).inserted {
                    names.append(name)
                }
            }
        }
        return names
    }

    @discardableResult
    mutating func renameSampleReferences(
        matching oldNames: Set<String>,
        to newName: String
    ) -> Int {
        let oldKeys = Set(oldNames.map(Self.normalizedSampleName))
        guard !oldKeys.isEmpty else { return 0 }

        var replacementCount = 0
        for index in keygroups.indices {
            if oldKeys.contains(
                Self.normalizedSampleName(keygroups[index].softSampleName)
            ) {
                keygroups[index].softSampleName = newName
                replacementCount += 1
            }
            if oldKeys.contains(
                Self.normalizedSampleName(keygroups[index].loudSampleName)
            ) {
                keygroups[index].loudSampleName = newName
                replacementCount += 1
            }
        }
        return replacementCount
    }

    mutating func appendKeygroups(
        records: [Data],
        sampleNameMapping: [String: String] = [:]
    ) throws {
        guard keygroups.count + records.count <= 99 else {
            throw P9ProgramError.tooManyKeygroups(keygroups.count + records.count)
        }
        for record in records where record.count != Self.keygroupSize {
            throw P9ProgramError.invalidKeygroupRecord(record.count)
        }

        for record in records {
            let transferSafeRecord = Self.clearingTransferredRuntimeAddresses(
                in: record
            )
            let index = keygroups.count
            var keygroup = P9Keygroup(id: index, record: transferSafeRecord)
            if let replacement = sampleNameMapping[keygroup.softSampleName.uppercased()] {
                keygroup.softSampleName = replacement
            }
            if let replacement = sampleNameMapping[keygroup.loudSampleName.uppercased()] {
                keygroup.loudSampleName = replacement
            }
            keygroupOriginalRecords.append(transferSafeRecord)
            keygroups.append(keygroup)
        }
        markStructureTransferSafe()
    }

    @discardableResult
    mutating func appendKeygroup(copying sourceIndex: Int?) throws -> Int {
        guard keygroups.count < 99 else {
            throw P9ProgramError.tooManyKeygroups(keygroups.count + 1)
        }
        let sourceRecord: Data
        if let sourceIndex {
            guard keygroups.indices.contains(sourceIndex) else {
                throw P9ProgramError.invalidKeygroup(sourceIndex)
            }
            sourceRecord = try keygroupRecords(at: [sourceIndex])[0]
        } else {
            sourceRecord = Self.defaultKeygroupRecord()
        }
        let record = Self.clearingTransferredRuntimeAddresses(in: sourceRecord)
        let index = keygroups.count
        keygroupOriginalRecords.append(record)
        keygroups.append(P9Keygroup(id: index, record: record))
        markStructureTransferSafe()
        return index
    }

    mutating func deleteKeygroups(at indexes: Set<Int>) throws {
        let validIndexes = indexes.filter { keygroups.indices.contains($0) }
        guard validIndexes.count == indexes.count else {
            throw P9ProgramError.invalidKeygroup(
                indexes.first(where: { !keygroups.indices.contains($0) }) ?? -1
            )
        }
        guard keygroups.count - validIndexes.count >= 1 else {
            throw P9ProgramError.mustKeepOneKeygroup
        }
        for index in validIndexes.sorted(by: >) {
            keygroups.remove(at: index)
            keygroupOriginalRecords.remove(at: index)
        }
        for index in keygroups.indices {
            keygroups[index].id = index
        }
        markStructureTransferSafe()
    }

    static func blank(named name: String) throws -> P9Program {
        var header = Data(repeating: 0, count: Self.headerSize)
        header.replaceSubrange(0x00..<0x0A, with: Self.encodedName(name))
        header[0x16] = 0xFF
        header[0x17] = 1
        header[0x1B] = 0xFF
        header.append(Self.defaultKeygroupRecord())
        return try P9Program(data: header)
    }

    private static func defaultKeygroupRecord() -> Data {
        var record = Data(repeating: 0, count: Self.keygroupSize)
        record[0x00] = 127
        record[0x01] = 0
        record[0x02] = 128
        record[0x03] = 0
        record[0x04] = 80
        record[0x05] = 99
        record[0x06] = 30
        record[0x0E] = 99
        record[0x0F] = 64
        record[0x10] = 42
        record[0x12] = 0x04
        record[0x13] = 0xFF
        record[0x16] = 50
        record.replaceSubrange(
            0x18..<0x22,
            with: Data(repeating: UInt8(ascii: " "), count: 10)
        )
        record[0x22] = 20
        record[0x23] = 20
        record[0x24] = 20
        record[0x25] = 20
        record[0x26] = 64
        record[0x2C] = 99
        record.replaceSubrange(
            0x2E..<0x38,
            with: Data(repeating: UInt8(ascii: " "), count: 10)
        )
        record[0x42] = 99
        return record
    }

    private static func clearingTransferredRuntimeAddresses(in record: Data) -> Data {
        var result = record
        for offset in transferredRuntimeAddressOffsets {
            result[offset] = 0
            result[offset + 1] = 0
        }
        return result
    }

    private static func normalizedSampleName(_ name: String) -> String {
        name.uppercased()
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private mutating func markStructureTransferSafe() {
        hasStructuralEdits = true
        keygroupOriginalRecords = keygroupOriginalRecords.map {
            Self.clearingTransferredRuntimeAddresses(in: $0)
        }
    }

    mutating func apply(_ edits: P9BulkEdits, to indexes: Set<Int>) {
        for index in indexes.sorted() where keygroups.indices.contains(index) {
            edits.apply(to: &keygroups[index])
        }
    }

    mutating func spread(_ settings: P9SpreadSettings, to indexes: Set<Int>) throws {
        let selectedIndexes = indexes.sorted().filter { keygroups.indices.contains($0) }
        try settings.validate(keygroupCount: selectedIndexes.count)

        for (offset, index) in selectedIndexes.enumerated() {
            let assignedNote = settings.startNote + offset
            keygroups[index].lowKey = assignedNote
            keygroups[index].highKey = assignedNote
            if let transpose = settings.transpose(forAssignedNote: assignedNote) {
                keygroups[index].softTuning =
                    keygroups[index].softTuning.replacingTranspose(transpose)
                keygroups[index].loudTuning =
                    keygroups[index].loudTuning.replacingTranspose(transpose)
            }
        }
    }

    private static func encodedName(_ name: String) -> Data {
        let ascii = name.uppercased().unicodeScalars.compactMap { scalar -> UInt8? in
            guard scalar.isASCII else { return nil }
            let value = UInt8(scalar.value)
            return value >= 0x20 && value <= 0x7E ? value : UInt8(ascii: "_")
        }
        let prefix = Array(ascii.prefix(10))
        return Data(prefix + Array(repeating: UInt8(ascii: " "), count: max(0, 10 - prefix.count)))
    }
}

enum P9BulkMode: String, CaseIterable, Identifiable {
    case set = "Set"
    case adjust = "Adjust"
    var id: String { rawValue }
}

enum P9NumericInput {
    static func boundedValue(_ text: String, range: ClosedRange<Int>) -> Int? {
        guard let parsed = Int(text.trimmingCharacters(in: .whitespaces)) else { return nil }
        return max(range.lowerBound, min(range.upperBound, parsed))
    }
}

struct P9BulkNumberEdit: Equatable {
    var enabled = false
    var mode: P9BulkMode = .set
    var value = 0

    func applying(to current: Int, range: ClosedRange<Int>) -> Int {
        guard enabled else { return current }
        let proposed = mode == .set ? value : current + value
        return max(range.lowerBound, min(range.upperBound, proposed))
    }
}

struct P9BulkEdits: Equatable {
    var lowKey = P9BulkNumberEdit()
    var highKey = P9BulkNumberEdit()
    var velocityThreshold = P9BulkNumberEdit()
    var velocityCrossfadePoint = P9BulkNumberEdit()

    var softLoudness = P9BulkNumberEdit()
    var softFilter = P9BulkNumberEdit()
    var softTranspose = P9BulkNumberEdit()
    var softFine = P9BulkNumberEdit()
    var loudLoudness = P9BulkNumberEdit()
    var loudFilter = P9BulkNumberEdit()
    var loudTranspose = P9BulkNumberEdit()
    var loudFine = P9BulkNumberEdit()

    var vcfAttack = P9BulkNumberEdit()
    var vcfDecay = P9BulkNumberEdit()
    var vcfSustain = P9BulkNumberEdit()
    var vcfRelease = P9BulkNumberEdit()
    var vcfAmount = P9BulkNumberEdit()

    var envAttack = P9BulkNumberEdit()
    var envDecay = P9BulkNumberEdit()
    var envSustain = P9BulkNumberEdit()
    var envRelease = P9BulkNumberEdit()

    var velocityLoudness = P9BulkNumberEdit()
    var velocityAttack = P9BulkNumberEdit()
    var velocityFilter = P9BulkNumberEdit()
    var velocityRelease = P9BulkNumberEdit()

    var softSampleName: String?
    var loudSampleName: String?
    var midiChannel: Int?
    var output: P9Output?
    var constantPitch: Bool?
    var velocityCrossfade: Bool?
    var oneShot: Bool?
    var releaseVelocityFromNoteOn: Bool?
    var customVelocityCrossfadePoint: Bool?

    var hasChanges: Bool {
        let numbers = [
            lowKey, highKey, velocityThreshold, velocityCrossfadePoint,
            softLoudness, softFilter, softTranspose, softFine,
            loudLoudness, loudFilter, loudTranspose, loudFine,
            vcfAttack, vcfDecay, vcfSustain, vcfRelease, vcfAmount,
            envAttack, envDecay, envSustain, envRelease,
            velocityLoudness, velocityAttack, velocityFilter, velocityRelease
        ]
        return numbers.contains(where: \.enabled)
            || softSampleName != nil
            || loudSampleName != nil
            || midiChannel != nil
            || output != nil
            || constantPitch != nil
            || velocityCrossfade != nil
            || oneShot != nil
            || releaseVelocityFromNoteOn != nil
            || customVelocityCrossfadePoint != nil
    }

    fileprivate func apply(to keygroup: inout P9Keygroup) {
        if let softSampleName {
            keygroup.softSampleName = String(softSampleName.uppercased().prefix(10))
        }
        if let loudSampleName {
            keygroup.loudSampleName = String(loudSampleName.uppercased().prefix(10))
        }
        keygroup.lowKey = lowKey.applying(to: keygroup.lowKey, range: 0...127)
        keygroup.highKey = highKey.applying(to: keygroup.highKey, range: 0...127)
        keygroup.velocityThreshold = velocityThreshold.applying(to: keygroup.velocityThreshold, range: 0...128)
        keygroup.velocityCrossfadePoint = velocityCrossfadePoint.applying(
            to: keygroup.velocityCrossfadePoint,
            range: 0...127
        )

        keygroup.softLoudness = softLoudness.applying(to: keygroup.softLoudness, range: -50...50)
        keygroup.softFilter = softFilter.applying(to: keygroup.softFilter, range: 0...99)
        keygroup.softTuning = P9Tuning(
            transpose: softTranspose.applying(
                to: keygroup.softTuning.transpose,
                range: P9Tuning.transposeRange
            ),
            fine: softFine.applying(
                to: keygroup.softTuning.fine,
                range: P9Tuning.fineRange
            )
        )
        keygroup.loudLoudness = loudLoudness.applying(to: keygroup.loudLoudness, range: -50...50)
        keygroup.loudFilter = loudFilter.applying(to: keygroup.loudFilter, range: 0...99)
        keygroup.loudTuning = P9Tuning(
            transpose: loudTranspose.applying(
                to: keygroup.loudTuning.transpose,
                range: P9Tuning.transposeRange
            ),
            fine: loudFine.applying(
                to: keygroup.loudTuning.fine,
                range: P9Tuning.fineRange
            )
        )

        keygroup.vcfEnvelope.attack = vcfAttack.applying(to: keygroup.vcfEnvelope.attack, range: 0...99)
        keygroup.vcfEnvelope.decay = vcfDecay.applying(to: keygroup.vcfEnvelope.decay, range: 0...99)
        keygroup.vcfEnvelope.sustain = vcfSustain.applying(to: keygroup.vcfEnvelope.sustain, range: 0...99)
        keygroup.vcfEnvelope.release = vcfRelease.applying(to: keygroup.vcfEnvelope.release, range: 0...99)
        keygroup.vcfAmount = vcfAmount.applying(to: keygroup.vcfAmount, range: -50...50)

        keygroup.envelope.attack = envAttack.applying(to: keygroup.envelope.attack, range: 0...99)
        keygroup.envelope.decay = envDecay.applying(to: keygroup.envelope.decay, range: 0...99)
        keygroup.envelope.sustain = envSustain.applying(to: keygroup.envelope.sustain, range: 0...99)
        keygroup.envelope.release = envRelease.applying(to: keygroup.envelope.release, range: 0...99)

        keygroup.velocitySensitivity.loudness = velocityLoudness.applying(
            to: keygroup.velocitySensitivity.loudness,
            range: 0...99
        )
        keygroup.velocitySensitivity.attack = velocityAttack.applying(
            to: keygroup.velocitySensitivity.attack,
            range: 0...99
        )
        keygroup.velocitySensitivity.filter = velocityFilter.applying(
            to: keygroup.velocitySensitivity.filter,
            range: 0...99
        )
        keygroup.velocitySensitivity.release = velocityRelease.applying(
            to: keygroup.velocitySensitivity.release,
            range: -50...50
        )

        if let midiChannel { keygroup.midiChannelOffset = max(0, min(15, midiChannel - 1)) }
        if let output { keygroup.output = output }
        if let constantPitch { keygroup.constantPitch = constantPitch }
        if let velocityCrossfade { keygroup.velocityCrossfade = velocityCrossfade }
        if let oneShot { keygroup.oneShot = oneShot }
        if let releaseVelocityFromNoteOn {
            keygroup.releaseVelocityFromNoteOn = releaseVelocityFromNoteOn
        }
        if let customVelocityCrossfadePoint {
            keygroup.customVelocityCrossfadePoint = customVelocityCrossfadePoint
        }
    }
}

extension P9Keygroup {
    var noteRangeDescription: String {
        "\(Self.noteName(lowKey))–\(Self.noteName(highKey))"
    }

    static func noteName(_ value: Int) -> String {
        let clamped = max(0, min(127, value))
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return "\(names[clamped % 12])\(clamped / 12 - 2)"
    }
}

private extension Data {
    func signedLittleEndian16(at offset: Int) -> Int16 {
        let unsigned = UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
        return Int16(bitPattern: unsigned)
    }

    mutating func writeSignedLittleEndian16(_ value: Int16, at offset: Int) {
        let unsigned = UInt16(bitPattern: value)
        self[offset] = UInt8(unsigned & 0x00FF)
        self[offset + 1] = UInt8((unsigned >> 8) & 0x00FF)
    }
}

private extension UInt8 {
    func setting(mask: UInt8, enabled: Bool) -> UInt8 {
        enabled ? self | mask : self & ~mask
    }
}

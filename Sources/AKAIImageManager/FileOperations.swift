import AppKit
import CryptoKit
import Foundation

struct TemporaryWorkspace {
    let url: URL

    init(prefix: String = "akai-manager") throws {
        let base = FileManager.default.temporaryDirectory
        url = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

struct LocalDirectoryAlias {
    let workspace: TemporaryWorkspace
    let aliasURL: URL

    init(destination: URL) throws {
        workspace = try TemporaryWorkspace(prefix: "akai-local")
        aliasURL = workspace.url.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: destination)
    }

    func remove() { workspace.remove() }
}

enum NativeAkaiFileExport {
    static func fileExtension(for filename: String) -> String? {
        let path = filename as NSString
        let fileExtension = path.pathExtension.uppercased()
        guard fileExtension == "S9" || fileExtension == "P9" else { return nil }
        let stem = path.deletingPathExtension.uppercased()
        guard !stem.hasSuffix(".S9"), !stem.hasSuffix(".P9") else { return nil }
        return fileExtension
    }

    static func isSupported(_ filename: String) -> Bool {
        fileExtension(for: filename) != nil
    }

    /// NSItemProvider's suggested name excludes the extension. Supplying the
    /// full filename makes Finder append the type's extension a second time.
    static func dragSuggestedName(for filename: String) -> String {
        (filename as NSString).deletingPathExtension
    }

    static func normalizeExportedFile(_ exportedURL: URL, expectedFilename: String) throws -> URL {
        guard fileExtension(for: expectedFilename) != nil else {
            throw AppError.verificationFailed("The requested native filename is not an S9 or P9 file.")
        }
        guard fileExtension(for: exportedURL.lastPathComponent) != nil else {
            throw AppError.verificationFailed("AKAI Util did not create an S9 or P9 file.")
        }

        let exactFilename = (expectedFilename as NSString).lastPathComponent
        let exactURL = exportedURL.deletingLastPathComponent().appendingPathComponent(exactFilename)
        guard exactURL.standardizedFileURL != exportedURL.standardizedFileURL else { return exportedURL }
        if exactURL.path.caseInsensitiveCompare(exportedURL.path) == .orderedSame {
            let intermediateURL = exportedURL.deletingLastPathComponent()
                .appendingPathComponent(".akai-case-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: exportedURL, to: intermediateURL)
            do {
                try FileManager.default.moveItem(at: intermediateURL, to: exactURL)
            } catch {
                try? FileManager.default.moveItem(at: intermediateURL, to: exportedURL)
                throw error
            }
            return exactURL
        }
        guard !FileManager.default.fileExists(atPath: exactURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.moveItem(at: exportedURL, to: exactURL)
        return exactURL
    }
}

enum S9PlaybackMode: UInt8, CaseIterable, Identifiable {
    case oneShot = 0x4F
    case loop = 0x4C
    case alternatingLoop = 0x41

    var id: UInt8 { rawValue }

    var title: String {
        switch self {
        case .oneShot: return "One-shot"
        case .loop: return "Loop"
        case .alternatingLoop: return "Alternating loop"
        }
    }

    var requiresLoopMarkers: Bool { self != .oneShot }
}

enum S9PlaybackDirection: UInt8, CaseIterable, Identifiable {
    case normal = 0x4E
    case reverse = 0x52

    var id: UInt8 { rawValue }
    var title: String { self == .normal ? "Forward" : "Reverse" }
}

struct S9SampleAttributes: Equatable {
    let sampleLength: UInt32
    let sampleRate: UInt16
    let nominalPitchSixteenths: UInt16
    let playbackMode: S9PlaybackMode
    let playbackDirection: S9PlaybackDirection
    let playbackStart: UInt32
    let playbackEnd: UInt32
    let loopLength: UInt32

    var rootNote: Int { Int(nominalPitchSixteenths) / 16 }
    var finePitchSixteenths: Int { Int(nominalPitchSixteenths) % 16 }
    var loopStart: UInt32? {
        guard loopLength > 0, playbackEnd >= loopLength else {
            return nil
        }
        return playbackEnd - loopLength
    }
}

struct S9SampleEditSettings: Equatable {
    var rootNote: Int
    var playbackMode: S9PlaybackMode
    var playbackDirection: S9PlaybackDirection

    init(
        rootNote: Int,
        playbackMode: S9PlaybackMode,
        playbackDirection: S9PlaybackDirection
    ) {
        self.rootNote = rootNote
        self.playbackMode = playbackMode
        self.playbackDirection = playbackDirection
    }

    init(attributes: S9SampleAttributes) {
        rootNote = attributes.rootNote
        playbackMode = attributes.playbackMode
        playbackDirection = attributes.playbackDirection
    }
}

struct S9LoopPoints: Equatable {
    var start: UInt32
    var end: UInt32

    func validated(sampleLength: UInt32) throws -> S9LoopPoints {
        guard start < end else {
            throw AppError.verificationFailed(
                "Loop start must be before loop end."
            )
        }
        guard end <= sampleLength else {
            throw AppError.verificationFailed(
                "Loop end must not exceed the sample length of \(sampleLength) samples."
            )
        }
        return self
    }
}

enum S9NativeSample {
    static let nameLength = 10
    static let headerLength = 0x3C

    private enum Offset {
        static let sampleLength = 0x10
        static let sampleRate = 0x14
        static let nominalPitch = 0x16
        static let playbackMode = 0x1A
        static let playbackEnd = 0x1C
        static let playbackStart = 0x20
        static let loopLength = 0x24
        static let playbackDirection = 0x2B
    }

    static func internalName(in data: Data) throws -> String {
        guard data.count >= nameLength else {
            throw AppError.verificationFailed(
                "The S9 file is too short to contain its native sample name."
            )
        }
        return String(decoding: data.prefix(nameLength), as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
    }

    static func renamingInternalName(in data: Data, to name: String) throws -> Data {
        guard data.count >= nameLength else {
            throw AppError.verificationFailed(
                "The S9 file is too short to contain its native sample name."
            )
        }
        var result = data
        result.replaceSubrange(0..<nameLength, with: encodedName(name))
        return result
    }

    static func renameInternalName(in file: URL, to name: String) throws {
        let original = try Data(contentsOf: file)
        let renamed = try renamingInternalName(in: original, to: name)
        try renamed.write(to: file, options: .atomic)
    }

    static func attributes(in data: Data) throws -> S9SampleAttributes {
        guard data.count >= headerLength else {
            throw AppError.verificationFailed(
                "The S9 file is too short to contain its native sample attributes."
            )
        }
        guard let playbackMode = S9PlaybackMode(
            rawValue: data[Offset.playbackMode]
        ) else {
            throw AppError.verificationFailed(
                "The S9 sample contains an unknown playback mode."
            )
        }
        guard let playbackDirection = S9PlaybackDirection(
            rawValue: data[Offset.playbackDirection]
        ) else {
            throw AppError.verificationFailed(
                "The S9 sample contains an unknown playback direction."
            )
        }
        return S9SampleAttributes(
            sampleLength: data.littleEndianUInt32(at: Offset.sampleLength),
            sampleRate: data.littleEndianUInt16(at: Offset.sampleRate),
            nominalPitchSixteenths: data.littleEndianUInt16(
                at: Offset.nominalPitch
            ),
            playbackMode: playbackMode,
            playbackDirection: playbackDirection,
            playbackStart: data.littleEndianUInt32(at: Offset.playbackStart),
            playbackEnd: data.littleEndianUInt32(at: Offset.playbackEnd),
            loopLength: data.littleEndianUInt32(at: Offset.loopLength)
        )
    }

    static func applying(
        _ settings: S9SampleEditSettings,
        cueSampleOffsets: [UInt32],
        editedWAVFrameCount: Int64,
        to data: Data,
        retainedFinePitchSixteenths: Int = 0,
        explicitLoopPoints: S9LoopPoints? = nil
    ) throws -> Data {
        let native = try attributes(in: data)
        guard native.sampleLength > 0 else {
            throw AppError.verificationFailed(
                "The converted S9 contains no sample frames."
            )
        }
        guard (0...127).contains(settings.rootNote) else {
            throw AppError.verificationFailed(
                "The S9 root pitch must be a MIDI note from 0 to 127."
            )
        }

        var result = data
        let fine = max(0, min(15, retainedFinePitchSixteenths))
        result.writeLittleEndianUInt16(
            UInt16(settings.rootNote * 16 + fine),
            at: Offset.nominalPitch
        )
        result[Offset.playbackMode] = settings.playbackMode.rawValue
        result[Offset.playbackDirection] = settings.playbackDirection.rawValue

        if settings.playbackMode.requiresLoopMarkers,
           explicitLoopPoints == nil,
           cueSampleOffsets.count != 2 {
            throw AppError.verificationFailed(
                "Looping requires exactly two standard WAV cue markers. "
                    + "The earlier marker is the loop start and the later marker is the loop end."
            )
        }

        if let explicitLoopPoints {
            let points = try explicitLoopPoints.validated(
                sampleLength: native.sampleLength
            )
            result.writeLittleEndianUInt32(points.end, at: Offset.playbackEnd)
            result.writeLittleEndianUInt32(
                points.end - points.start,
                at: Offset.loopLength
            )
        } else if cueSampleOffsets.count == 2 {
            guard editedWAVFrameCount > 0 else {
                throw AppError.verificationFailed(
                    "The edited WAV has no usable audio frames for its loop markers."
                )
            }
            let ordered = cueSampleOffsets.sorted()
            guard ordered[0] < ordered[1],
                  Int64(ordered[1]) <= editedWAVFrameCount
            else {
                throw AppError.verificationFailed(
                    "The two WAV cue markers must be different, ordered and within the edited audio."
                )
            }
            let nativeFrameCount = Int64(native.sampleLength)
            func scaled(_ sourceFrame: UInt32) -> UInt32 {
                let position = Double(sourceFrame)
                    * Double(nativeFrameCount)
                    / Double(editedWAVFrameCount)
                return UInt32(
                    max(0, min(nativeFrameCount, Int64(position.rounded())))
                )
            }
            let loopStart = scaled(ordered[0])
            let loopEnd = scaled(ordered[1])
            guard loopStart < loopEnd else {
                throw AppError.verificationFailed(
                    "The WAV cue markers collapse to the same S950 sample frame after conversion."
                )
            }
            result.writeLittleEndianUInt32(loopEnd, at: Offset.playbackEnd)
            result.writeLittleEndianUInt32(
                loopEnd - loopStart,
                at: Offset.loopLength
            )
        } else if native.playbackEnd > native.sampleLength
            || native.loopLength > native.playbackEnd {
            result.writeLittleEndianUInt32(
                native.sampleLength,
                at: Offset.playbackEnd
            )
            result.writeLittleEndianUInt32(0, at: Offset.loopLength)
        }
        return result
    }

    static func nativeHeaderForWAVImport(
        existingHeader: Data?,
        preparedFrameCount: Int64,
        preparedSampleRate: Double,
        cueSampleOffsets: [UInt32],
        sourceFrameCount: Int64
    ) throws -> Data {
        guard preparedFrameCount > 0,
              preparedFrameCount <= Int64(UInt32.max)
        else {
            throw AppError.verificationFailed(
                "The prepared WAV has an unsupported sample-frame count."
            )
        }
        var header: Data
        if let existingHeader {
            guard existingHeader.count == headerLength else {
                throw AppError.verificationFailed(
                    "The WAV's existing native S9 header has an unexpected size."
                )
            }
            header = existingHeader
        } else {
            header = Data(repeating: 0, count: headerLength)
            header.replaceSubrange(0..<nameLength, with: encodedName("SAMPLE"))
            header.writeLittleEndianUInt16(60 * 16, at: Offset.nominalPitch)
            header[Offset.playbackMode] = S9PlaybackMode.oneShot.rawValue
            header[Offset.playbackDirection] = S9PlaybackDirection.normal.rawValue
        }
        header.writeLittleEndianUInt32(
            UInt32(preparedFrameCount),
            at: Offset.sampleLength
        )
        let sampleRate = max(
            1,
            min(Int(UInt16.max), Int(preparedSampleRate.rounded()))
        )
        header.writeLittleEndianUInt16(UInt16(sampleRate), at: Offset.sampleRate)
        let original = try attributes(in: header)
        return try applying(
            S9SampleEditSettings(attributes: original),
            cueSampleOffsets: cueSampleOffsets,
            editedWAVFrameCount: sourceFrameCount,
            to: header,
            retainedFinePitchSixteenths: original.finePitchSixteenths
        )
    }

    private static func encodedName(_ name: String) -> Data {
        let ascii = name.uppercased().unicodeScalars.compactMap { scalar -> UInt8? in
            guard scalar.isASCII else { return nil }
            let value = UInt8(scalar.value)
            return value >= 0x20 && value <= 0x7E ? value : UInt8(ascii: "_")
        }
        let prefix = Array(ascii.prefix(nameLength))
        return Data(
            prefix + Array(
                repeating: UInt8(ascii: " "),
                count: max(0, nameLength - prefix.count)
            )
        )
    }
}

private extension Data {
    func littleEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    mutating func writeLittleEndianUInt16(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    mutating func writeLittleEndianUInt32(_ value: UInt32, at offset: Int) {
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8) & 0xFF)
        self[offset + 2] = UInt8((value >> 16) & 0xFF)
        self[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}

enum ImageFileOperations {
    static func createZeroFilledImage(at url: URL, byteCount: UInt64) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: byteCount)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    static func timestampedBackup(
        of source: URL,
        destinationDirectory: URL? = nil,
        now: Date = Date()
    ) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let extensionText = source.pathExtension
        let sourceStem = source.deletingPathExtension().lastPathComponent
        let stem = originalStem(forBackupStem: sourceStem)
        let timestampedStem = "\(stem)-backup-\(formatter.string(from: now))"
        let directory = destinationDirectory ?? source.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw AppError.verificationFailed(
                "The IMG backup folder is unavailable: \(directory.path)"
            )
        }
        func backupURL(suffix: String = "") -> URL {
            directory.appendingPathComponent(
                timestampedStem + suffix
                    + (extensionText.isEmpty ? "" : ".\(extensionText)")
            )
        }
        var destination = backupURL()
        if FileManager.default.fileExists(atPath: destination.path) {
            for number in 2...999 {
                let candidate = backupURL(suffix: "-\(number)")
                if !FileManager.default.fileExists(atPath: candidate.path) {
                    destination = candidate
                    break
                }
            }
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try copyAtomicallyAndVerify(source: source, destination: destination)
        return destination
    }

    private static func originalStem(forBackupStem stem: String) -> String {
        let pattern = #"-backup-\d{4}-\d{2}-\d{2}-\d{6}(?:-\d+)?$"#
        var normalized = stem
        while let range = normalized.range(
            of: pattern,
            options: [.regularExpression, .caseInsensitive]
        ) {
            normalized.removeSubrange(range)
        }
        return normalized.isEmpty ? stem : normalized
    }

    static func updateModificationDate(
        of imageURL: URL,
        to date: Date = Date()
    ) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: imageURL.path
        )
    }

    static func mountedVolumes() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes", isDirectory: true),
            includingPropertiesForKeys: [.volumeIsRemovableKey, .volumeIsEjectableKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    static func copyAtomicallyAndVerify(source: URL, destination: URL) throws {
        let manager = FileManager.default
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).akai-copy-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: temporary) }
        try manager.copyItem(at: source, to: temporary)
        let handle = try FileHandle(forUpdating: temporary)
        try handle.synchronize()
        try handle.close()

        let sourceSize = try fileSize(source)
        let temporarySize = try fileSize(temporary)
        guard sourceSize == temporarySize else {
            throw AppError.verificationFailed("The copied file size differs from the source.")
        }
        guard try checksum(source) == checksum(temporary) else {
            throw AppError.verificationFailed("The copied image checksum differs from the source.")
        }

        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temporary, backupItemName: nil)
        } else {
            try manager.moveItem(at: temporary, to: destination)
        }
        guard try fileSize(source) == fileSize(destination) else {
            throw AppError.verificationFailed(
                "The final destination size differs from the verified source."
            )
        }
        guard try checksum(source) == checksum(destination) else {
            throw AppError.verificationFailed(
                "The final destination checksum differs from the verified source."
            )
        }
    }

    static func exactUSBcleanURL(preferredPath: String) -> URL? {
        let preferred = URL(fileURLWithPath: preferredPath)
        if FileManager.default.fileExists(atPath: preferred.path) { return preferred }
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let candidates = try? FileManager.default.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil)
        return candidates?.first {
            $0.pathExtension.caseInsensitiveCompare("app") == .orderedSame
                && $0.lastPathComponent.localizedCaseInsensitiveContains("usbclean")
        }
    }

    static func handToUSBclean(volume: URL, application: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await NSWorkspace.shared.open([volume], withApplicationAt: application, configuration: configuration)
    }

    static func waitUntilUnmounted(
        volume: URL,
        timeout: TimeInterval = 60,
        pollIntervalNanoseconds: UInt64 = 250_000_000
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while FileManager.default.fileExists(atPath: volume.path) {
            try Task.checkCancellation()
            guard Date() < deadline else {
                throw AppError.verificationFailed(
                    "\(volume.lastPathComponent) is still mounted. Wait for USBclean to finish before unplugging it."
                )
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }

    private static func fileSize(_ url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return UInt64(values.fileSize ?? 0)
    }

    private static func checksum(_ url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize()
    }
}
